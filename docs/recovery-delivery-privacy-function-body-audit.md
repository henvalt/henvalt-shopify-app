# Recovery, Delivery, Consent and Privacy Function-Body Audit

**Inspection date:** 2026-11-16  
**Environment:** live HENVALT Supabase production, read-only catalog/source inspection  
**Branch:** `prep/public-app-hardening-2026-11-15`  
**Safety:** no function, table, row, trigger, workflow, or deployment was changed.

## Executive result

The previous RPC inventory established that important functions do not accept a `shopify_connection_id`. Inspection of their deployed function bodies now confirms concrete cross-store hazards, not just missing future-proofing.

The highest-risk patterns are:

1. Candidate discovery joins a tenant's Shopify connections without binding the event/session/customer to one exact connection. In a tenant with two active stores, a single tenant-scoped event/customer can be paired with either connection.
2. Candidate and conversion-stop queries compare orders, checkouts, customers and events by tenant/customer/session, so activity in one store can affect recovery in another store.
3. Delivery authorization validates some active-shop metadata for cart/browse/checkout, but its conversion checks and suppressions are tenant/customer scoped. It does not prove that request, intervention, opportunity, customer, checkout, order and active connection all belong to the same store.
4. Unsubscribe is tenant-wide: a token generated from one intervention changes the tenant-scoped customer consent, creates a tenant-scoped email suppression and suppresses recovery for that customer across the tenant.
5. Customer privacy redaction accepts tenant + Shopify customer ID/email, then deletes or anonymizes tenant-matching records without a shop-connection predicate. Shopify customer IDs and emails are not reliable store identity.
6. Shop redaction deletes the entire tenant after marking the privacy request completed. This is unacceptable for a shop-level compliance request when the tenant has multiple stores.

These are blockers for enabling multiple independent Shopify stores under one HENVALT tenant. Until fixed, fail closed for ambiguous tenant/store data rather than selecting a connection heuristically.

## 1. Candidate discovery: concrete store ambiguity

### Abandoned cart

Deployed `get_abandoned_cart_candidates`:

- Selects latest cart snapshots with `DISTINCT ON (tenant_id, session_reference)`.
- Joins `shopify_connections` using only `sc.tenant_id = e.tenant_id AND sc.active = true`; there is no exact shop-domain or connection predicate in this CTE.
- Matches Shopify Pixel events to cart snapshots by tenant, event type, timestamp and product variant; no connection ID or verified shop identity is part of that match.
- Resolves customer by `tenant_id + shopify_customer_id`.
- Joins every active connection for the tenant again and returns `sc.shop_domain`.
- Later checkout/order exclusion checks use tenant + session/customer, not exact store.

**Impact:** where a tenant has two active connections, a tenant-level cart snapshot/customer can join to multiple active shops. The returned `shop_domain` can be wrong or duplicated. A checkout/order in another store may suppress the cart recovery. This function must not be used as a multi-store candidate source until exact lineage is present.

### Abandoned checkout

Deployed `get_abandoned_checkout_candidates` has a stronger partial predicate:

- Joins connection using tenant plus `lower(sc.shop_domain) = lower(ck.metadata->>'shop_domain')` and active status.
- However, the parent checkout row has no explicit connection FK in the inspected schema contract; shop identity is still metadata-based.
- Source event selection, order conversion checks, prior recovery sequence, active sequence and open opportunity checks remain tenant/checkout/customer scoped.
- Order exclusion can suppress a checkout when the same tenant/customer has a qualifying order after checkout update, even if that order belongs to a different store.

**Impact:** metadata matching narrows the active connection, but it does not establish referential integrity or protect downstream order/attribution checks from cross-store matches.

### Browse abandonment

Deployed `get_browse_abandonment_candidates`:

- Joins customers by tenant + Shopify customer ID.
- Joins every active Shopify connection by tenant only; it does not join the pixel event to a specific connection.
- Ranks/reconciles pixel events by tenant + session + product.
- Suppresses candidates using later pixel events and checkouts keyed by tenant + session/alias, not connection.

**Impact:** candidate store identity can be ambiguous in a multi-store tenant, and activity from another store may suppress the candidate.

### Recovery worker context

Deployed `get_recovery_worker_context` loads its legacy context by intervention ID, resolves opportunity by tenant + opportunity ID, then checks connection activity by tenant + `opportunity.metadata.shop_domain` for cart/browse. It checks paid orders by tenant + customer and time, without store identity. The returned context does not expose a validated connection ID.

**Impact:** even if a candidate originally came from the right store, later worker context can still treat an order in another store as conversion and suppress the wrong recovery.

## 2. Delivery authorization: partial checks, incomplete same-store invariant

Deployed `authorize_delivery_request` checks:

- Tenant is active.
- Delivery request IDs, intervention/recovery/opportunity IDs, recipient and idempotency key match.
- Intervention, sequence and opportunity exist under the same tenant and have sendable states.
- Cart/browse opportunities have an active connection matching `opportunity.metadata.shop_domain`.
- Checkout opportunities join checkout metadata shop domain to an active connection.
- Recipient matches customer email and communication eligibility passes.
- Active email suppression is checked by tenant + customer or normalized email.
- Sender identity and provider configuration are selected by tenant.

Gaps found in the function body:

- No `shopify_connection_id` is loaded from or compared across request → intervention → sequence → opportunity → customer → checkout → source event.
- Cart/browse order-conversion checks use tenant + customer + time, not same connection.
- Cart-to-checkout advancement checks use tenant + customer + cart token, not same connection.
- Checkout conversion checks use tenant + checkout ID; the checkout's metadata-based connection is not propagated to the order comparison.
- The suppression check is tenant-wide.
- Sender identity is tenant-level and chosen as the newest active tenant identity, without an explicit per-store override policy.

**Required invariant:** resolve one trusted connection from the opportunity's immutable source lineage; require every related Shopify-originated row and current active connection to match that same ID before claiming a delivery. The request must be denied if lineage is absent, conflicting, inactive, or ambiguous.

## 3. Unsubscribe and consent: current tenant-wide semantics

### Token creation

`create_unsubscribe_token(p_intervention_id)` resolves intervention → opportunity → customer by tenant, creates a random 24-byte token, stores only its SHA-256 hash, and records intervention ID in metadata. It does not persist an explicit connection ID on the token.

### Token validation

`validate_unsubscribe_token(p_token)` checks only whether the token hash exists. It does not check used/expired state or return the originating delivery/connection context.

### Unsubscribe execution

`unsubscribe_customer_by_token(p_token)`:

- Resolves token to tenant + customer and customer's email.
- Sets the tenant-level customer `email_consent=false`.
- Inserts tenant-level `email_suppressions`.
- Calls `suppress_customer_recovery(tenant_id, customer_id, ...)`, which cancels/suppresses recovery by tenant + customer.
- Marks the token used and writes tenant audit log.

**Important policy decision:** Shopify's customer identity and consent are store-scoped. HENVALT may choose to provide an additional tenant-wide suppression preference, but it must be explicit, transparent and separately represented. Do not accidentally suppress a shopper's marketing in every independent store because they unsubscribed from one store's recovery email. At minimum, persist exact source connection and apply the merchant's configured scope.

### Consent updates

`apply_shopify_email_consent_update` accepts tenant + Shopify customer ID + email + consent + metadata, not a connection. Because Shopify customer IDs can repeat across shops, its lookup/update contract must become connection-aware before multiple stores share a tenant.

## 4. Privacy redaction: high-severity scope issue

### Customer redaction

`redact_shopify_customer_data(p_tenant_id, p_shopify_customer_id, p_customer_email)`:

- Finds customer rows by tenant and either Shopify customer ID or email.
- Selects checkouts, opportunities, sessions, messages, delivery attempts, provider events, suppression rows, webhook/error/background/audit payloads and conversation data by tenant + customer/email/opportunity lineage.
- Deletes canonical events matching tenant + customer ID/email.
- Anonymizes matching checkouts/orders/sessions and delivery records by tenant.
- Deletes tenant-matching customer row(s), cascading conversations and unsubscribe tokens.

There is no shop-connection predicate. This can redact records for another store in the same tenant when IDs or emails overlap or when tenant-wide customer matching is used.

**Required future contract:** `(privacy_request_id, shopify_connection_id, shopify_customer_id, customer_email)` or an equivalent trusted request object. Resolve exact connection from the verified webhook app key + shop domain + historical connection. Every deleted/anonymized record must be selected through that exact connection. Unmatched/uninstalled shops remain in a durable unresolved state; do not guess.

### Shop redaction

`redact_shopify_shop_data(p_privacy_request_id)`:

- Loads the `shop/redact` request.
- If tenant is known, clears the request payload/tenant link and marks it completed.
- Executes `DELETE FROM henvalt.tenants WHERE id = v_tenant_id`.

This is tenant deletion, not store deletion. It would destroy the whole HENVALT tenant and other stores' records if one tenant has multiple Shopify connections.

**This must be redesigned before public distribution.** A shop-level request must target the exact connection and its store-originated data, while preserving tenant membership, other stores, shared MailerSend provider config and shared account data according to documented retention rules. The compliance receipt must survive. Never treat a missing/ambiguous connection as permission to delete the tenant.

## 5. Cross-store invariant matrix

| Area | Current key observed | Required store-safe key |
|---|---|---|
| Cart snapshots | tenant + session | connection + session |
| Pixel-to-cart match | tenant + time + variant | connection + consented session + event |
| Customer resolution | tenant + Shopify customer ID | connection + Shopify customer ID |
| Checkout resolution | tenant + checkout ID/token; shop in metadata | connection + external checkout ID/token |
| Browse ranking | tenant + session + product | connection + session + product |
| Conversion stop | tenant + customer + time | connection + customer/order lineage |
| Delivery authorization | tenant + recovery lineage | tenant + connection + full lineage |
| Suppression | tenant + customer/email | explicit per-store or tenant-wide policy |
| Privacy customer redact | tenant + customer ID/email | exact connection + customer ID/email |
| Privacy shop redact | tenant deletion | exact connection data deletion |

## 6. Safe staged remediation sequence

1. Keep current production single-store behavior intact while preparing changes.
2. Add app-key and connection identity to trusted webhook resolution; persist the exact connection ID on each Shopify-originated source event.
3. Add nullable connection references to customer, checkout, opportunity, order and downstream operational records only after collision diagnostics. Keep unresolved records quarantined.
4. Change candidate queries so every event/customer/checkout/order join uses the same connection ID. Remove unqualified joins to all active connections.
5. Change recovery context and delivery authorization to enforce the same connection invariant and current active status.
6. Carry exact connection lineage through delivery, conversation, inbound reply and tracking; keep MailerSend provider credentials tenant/provider-scoped.
7. Decide per-store vs tenant-wide suppression; migrate tokens to retain originating connection and explicit policy.
8. Replace customer/shop privacy RPCs with exact-store operations; prove shop-redact cannot delete the tenant or other connections' records.
9. Add regression fixtures for a tenant with two stores that intentionally reuse the same Shopify customer ID, checkout token, session reference and customer email.
10. Only after all tests pass, prepare a migration for separate human review. No production apply is included in this branch work.

## 7. Required regression scenarios

- Two active stores under one tenant; cart event from store A must never be returned with store B's domain.
- Same Shopify customer ID in A and B must create two distinct HENVALT customer identities.
- Same checkout token/session reference in A and B must not collide or suppress each other's opportunities.
- Paid order in B must not stop recovery in A.
- Cart-to-checkout advancement in B must not stop cart recovery in A.
- Unsubscribe from A must follow the explicitly selected store/tenant suppression policy and never silently alter B.
- Customer redact in A must preserve B's customer/events/orders/messages.
- Shop redact for A must preserve tenant, B, shared provider credentials, and other stores' data.
- Missing/ambiguous/uninstalled store connection must produce a durable review-required privacy result, not tenant deletion.
- Legacy app requests must continue to resolve to legacy app identity after a new app identity is introduced.



## 8. Ingress, identity resolution, consent and order-attribution function-body findings

A further read-only pass inspected the deployed customer/checkout upserts, event identity resolver, consent update, browse-advance check, order projection, attribution and recovery-stop functions.

### Customer and checkout identity

- `upsert_customer` resolves an existing row by tenant + Shopify customer ID; when the external ID is absent it falls back to tenant + normalized email. It has no connection argument. This permits a customer from one shop to be merged with a tenant customer originally created from another shop when email is the fallback identity.
- `resolve_identity` resolves Shopify customer IDs and email by tenant; session aliases and sessions are also keyed by tenant. The same session/alias string in two shops can collide or be reused across stores.
- `upsert_checkout` is tenant-scoped and has no connection argument. Its uniqueness/idempotency is tenant-based, with metadata carrying shop domain. The external checkout ID/token is not structurally scoped to a Shopify connection.
- `upsert_canonical_event` deduplicates by tenant + idempotency key. It records metadata but does not require an exact connection.

### Consent update

`apply_shopify_email_consent_update` selects a customer by tenant and either Shopify customer ID or email, orders Shopify ID matches first, then takes one row with `LIMIT 1`. It calls tenant-scoped `upsert_customer`. When consent is revoked, it suppresses tenant-scoped opportunities, pending deliveries, interventions and sequences for the resolved customer.

This combines two risks: a same-email match may resolve the wrong store's customer, and the subsequent suppression is tenant-wide for that HENVALT customer. The exact Shopify connection must be resolved from the verified webhook before selecting the customer; consent and recovery suppression must follow the documented store/tenant policy.

### Browse advancement

`browse_opportunity_advanced` checks later pixel events and checkouts by tenant + session reference (and tenant-scoped session aliases), without a connection predicate. A later add-to-cart or checkout event from another shop sharing a tenant/session value can mark the browse opportunity as advanced.

### Order projection

`project_order_from_event` resolves the source event by event ID, but subsequent order/customer/checkout lookups are tenant-scoped:

- Existing order is selected by tenant + Shopify order ID.
- Customer is selected by tenant and Shopify customer ID or email.
- Checkout is selected by tenant + Shopify checkout ID.
- Metadata records the source event ID but does not enforce a same-connection FK.

A matching customer email or reused external ID in another store can bind the projected order to the wrong customer/checkout within the tenant.

### Attribution and conversion stop

`evaluate_order_attribution` matches tracking token within tenant (token lineage), checkout opportunities by tenant + checkout ID, and fallback customer attribution by tenant + customer ID. It has no connection check between order and opportunity/intervention. Customer-only matches are marked POSSIBLE/non-billable, but even diagnostic attribution must not cross stores.

`browse_opportunity_advanced`, `authorize_delivery_request`, and `get_recovery_worker_context` all use tenant-scoped customer/session/order checks for conversion or advancement. `stop_recovery_after_order` resolves attribution/order by tenant and then stops a recovery sequence by recovery ID or tenant-scoped checkout/tracking token. These functions must all consume the same trusted connection identity, not independently infer it from metadata.

`process_shopify_revenue_adjustment` resolves orders and ledger rows by tenant + Shopify order ID. It also needs the source event's connection ID and must update only the matching store's order/ledger entry.

### Consequence for implementation

A connection FK is not sufficient by itself. Every writer and every reader must enforce the invariant. The migration design must include connection-aware lookup and uniqueness semantics for customers, checkouts, canonical events, opportunities and orders; then propagate the same connection through attribution, recovery-stop, billing and revenue adjustments. Email is a contact attribute, never a substitute for Shopify source identity.

## 9. Live data diagnostic snapshot (2026-11-16)

The five SELECT-only diagnostics in `docs/sql/candidate-cross-store-ambiguity-review-only.sql` were also executed read-only against production.

- One tenant currently has **two active Shopify connections**: `hencalt.myshopify.com` and `hencalt.mystore.com`.
- The current snapshot returned no cart-update canonical events and no browse/product-view or add-to-cart pixel events in that multi-store tenant, so the candidate fan-out query returned no current event rows.
- The same tenant currently returned no customer, checkout or opportunity rows missing `metadata.shop_domain`.
- The customer-ID collision diagnostic returned no rows.
- This does **not** make the deployed function contracts safe. The cart and browse SQL joins still attach every active connection in a tenant to matching tenant-level events even if event metadata contains a shop domain, because that domain is not part of those connection join predicates. The current data snapshot simply has no qualifying cart/pixel source rows to demonstrate the fan-out at this moment.
- The absence of current collision rows is not evidence that tenant-scoped unique constraints are suitable for multi-store operation. Existing constraints can prevent duplicate same-tenant external IDs from being stored in the first place; they cannot prove source identities are correctly isolated.

The diagnostic SQL was corrected to measure all candidate events in multi-store tenants, not only rows with missing shop markers. It remains SELECT-only and has a Node test guarding against mutation statements.

## Explicit non-actions

No production function was replaced, no SQL migration was applied, no data was modified, no n8n workflow was changed, no Worker setting or secret was changed, and no Shopify app version was released.
