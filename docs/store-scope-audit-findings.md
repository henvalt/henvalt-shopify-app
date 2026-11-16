# Store-identity audit findings (read-only production inspection)

**Status:** investigation artifact only. Live Supabase queries used for this audit were read-only. No schema, data, Edge Function, n8n workflow, Worker, or Shopify app was changed.

**Scope:** deployed `henvalt` database function catalog and selected function definitions, compared with the existing public-app hardening contract. This is not yet a complete inventory of every reader/writer.

## Executive result

The current database contract is tenant-scoped in several critical paths where the public multi-store app requires store/connection scope. The highest-risk findings are:

1. Shopify customer identity, consent and suppression can cross stores inside one tenant.
2. Customer privacy export/redaction APIs accept tenant + Shopify customer ID/email but no exact Shopify connection.
3. `shop/redact` processing can delete the entire tenant; this is unsafe if one tenant owns multiple Shopify connections unless tenant deletion is explicitly the intended Shopify legal boundary.
4. Dashboard and billing summary functions resolve a shop, then aggregate tenant-wide data.
5. Inbound email reply routing uses a tenant conversation token and sender email, but conversation lineage has no direct Shopify connection binding.
6. Recovery candidate RPCs return shop domain but not a trusted connection ID; candidate processing still needs an authoritative connection binding.

These are design blockers, not evidence of cross-store leakage having occurred in current production data.

## Verified database findings

### 1. Customer identity and consent

- `upsert_customer(p_tenant_id, p_shopify_customer_id, ...)` identifies customers within a tenant, not within a Shopify connection. The inspected implementation also falls back to tenant + normalized email.
- `apply_shopify_email_consent_update(p_tenant_id, p_shopify_customer_id, p_email, ...)` searches by tenant and customer ID OR email, then calls the tenant-scoped customer upsert.
- When consent is revoked, the function suppresses opportunities and cancels sequences/interventions/delivery requests for that tenant/customer.
- `suppress_customer_recovery(p_tenant_id,p_customer_id,...)` is tenant/customer scoped, which is appropriate only after the customer ID is known to represent one unambiguous store identity.
- `unsubscribe_customer_by_token(p_token)` resolves token → tenant/customer, then sets consent false, creates a tenant/email suppression, and invokes tenant/customer recovery suppression. The token itself does not currently establish an app/connection boundary.

**Required design:** Shopify customer identity and Shopify-originated consent/suppression must be connection-scoped. Email equality must not merge separate Shopify customer identities. A separate tenant-wide suppression layer may exist only as an explicit policy, not as an accidental side effect.

### 2. Privacy export and redaction

- `export_shopify_customer_data(p_tenant_id,p_shopify_customer_id,p_customer_email)` has no connection argument. Its customer lookup and data collection are tenant-wide and can match by email across the tenant.
- `redact_shopify_customer_data(p_tenant_id,p_shopify_customer_id,p_customer_email)` has the same missing connection boundary. Its deletion/sanitization cascades through tenant-scoped customer, checkout, opportunity, event, delivery, message, suppression, and audit data.
- `redact_shopify_shop_data(p_privacy_request_id)` resolves a privacy request to `tenant_id`, detaches/sanitizes the receipt, then deletes the tenant. This must be reviewed against Shopify's shop-level compliance semantics before public multi-store use; a tenant can contain multiple active Shopify connections.
- The privacy request handler and request table need a trusted shop-domain + app-identity → exact connection resolution, including an unresolved durable state for an uninstalled or unmapped shop. No tenant-wide action may be inferred from an ambiguous shop mapping.

**Required design:** privacy requests need exact app identity, shop domain, and connection/history resolution. Customer export/redaction must operate on the exact store's data and dependent lineage. Shop redaction must have an explicit policy for tenant sharing; do not silently delete other stores' data.

### 3. Dashboard and billing summaries

- `control_plane_dashboard_summary(p_shop_domain,p_from,p_to)` resolves one active connection by shop, but its opportunity, intervention, attribution, ledger and event breakdown queries filter by `tenant_id`, not connection. The response is therefore tenant-wide for a store-addressed request.
- `control_plane_billing_summary(p_shop_domain)` resolves a tenant from the shop and aggregates billing measurements and email usage by tenant. `billing_accounts` is keyed by tenant, so it cannot represent independent Shopify billing subscriptions for two shops within one tenant.
- `control_plane_claim_billing_usage(p_shop_domain)` selects the tenant's billing account and tenant-level measurements/ledger rows. It is not yet a store-scoped charge claim path.

**Required design:** store-addressed dashboard and billing endpoints must filter by the selected connection. If tenant-wide views are supported, they must be explicit and separately labelled. Billing model must decide whether Shopify billing is per store or per tenant before schema constraints are drafted; current table shape is tenant-level.

### 4. Recovery candidate discovery

Catalog signatures show:
- `get_abandoned_cart_candidates(...)` returns tenant/customer/session/shop_domain and source event, but no connection ID.
- `get_abandoned_checkout_candidates(...)` returns tenant/checkout/customer/source event/shop_domain, but no connection ID.
- `get_browse_abandonment_candidates(...)` returns tenant/customer/session/source event/shop_domain, but no connection ID.
- The three `process_*_candidates` functions also have no connection parameter.

The prior audit of function bodies found candidate selection joins active connections using tenant/shop metadata, but the public multi-store contract needs the exact connection to be returned and preserved through opportunity → intervention → delivery. Shop domain as mutable JSON metadata is not a sufficient trusted foreign-key lineage.

**Required design:** candidates must return authoritative `shopify_connection_id`; all parent/child records and conversion-stop queries must be constrained to that same connection. Missing/ambiguous mappings must be quarantined, not guessed.

### 5. Inbound replies and conversations

- `process_mailersend_inbound_reply(p_payload,p_raw_body_base64)` verifies/deduplicates provider events, extracts a signed reply token from the inbound recipient address, resolves a conversation by token hash and checks that the sender email matches the conversation customer.
- It then appends a message and pauses recovery or applies opt-out suppression through tenant/customer identity.
- The conversation table has tenant lineage and related delivery/opportunity/recovery references, but no direct Shopify connection ID. The reply token provides a strong conversation route, but store scope must be inherited and validated through the complete originating delivery/recovery lineage.
- `get_mailersend_reply_to_for_delivery(p_tenant_id,p_delivery_request_id)` is tenant/request scoped; it must not generate a reply route for a delivery whose store lineage is missing or inconsistent.

**Required design:** inbound replies must resolve the exact originating delivery request and its opportunity/recovery/customer/connection chain. Never route a reply by email alone. Store-specific branding, reply AI settings and product context need an explicit scope decision; shared tenant defaults may remain, with store overrides.

### 6. Unsubscribe tokens and suppression

- `create_unsubscribe_token(p_intervention_id)` derives tenant/customer from intervention → opportunity and checks communication eligibility, but the token metadata stores intervention ID without a connection ID.
- `unsubscribe_customer_by_token` applies suppression at tenant/customer/email scope.
- This is safe only while tenant customer identity is unambiguous. With multiple shops, the token should preserve its originating store and unsubscribe must suppress that store's identity; any cross-store suppression should be an explicit, documented consent policy.

## Cross-check against current schema observations

Previously verified live schema/data observations remain relevant:
- Four active Shopify connections across three tenants; one tenant has two active connections.
- Customer, checkout, opportunity, order, event, recovery and ledger uniqueness is predominantly tenant-scoped.
- `pixel_keys` already carries an explicit `shopify_connection_id` FK and must retain that strong binding.
- Existing rows without trusted shop lineage must remain unresolved; no backfill may infer store from the only currently active connection.

## Migration implications (not SQL to apply)

Do not draft or apply a production migration until the remaining schema and caller inventory is complete. Expected additive direction, subject to full review:
- Add an app identity registry and connection-level app identity.
- Add nullable connection foreign keys to Shopify-originated source and downstream records, preserving existing tenant FKs.
- Introduce connection-aware RPC overloads/new versions; keep legacy signatures compatible during a controlled transition.
- Backfill only when source lineage is deterministic and unique; emit mapped, missing, ambiguous and conflicting counts separately.
- Add composite uniqueness only after collision preflight and explicit reconciliation.
- Preserve tenant-level MailerSend provider credentials; do not conflate provider secrets with Shopify app secrets.
- Preserve the existing pixel-key → connection FK.
- Keep all migration SQL review-only until separately authorized.

## Remaining audit work

Still required before the migration draft is considered complete:
- Full column/FK/unique-index inventory for privacy request receipts, consent/suppression, unsubscribe, provider events, conversations, settings and dashboard-facing views.
- Full definitions and caller inventory for every candidate, process, conversion-stop, delivery authorization, reply-context and dashboard RPC.
- Confirm all deployed Edge Function call sites and active n8n node arguments against the exact RPC signatures.
- Audit dynamic SQL, triggers and views that read tenant-scoped entities.
- Build a dependency graph from Shopify connection → source event → customer/checkout → opportunity → recovery/intervention → delivery/reply → order/attribution/ledger/billing.
- Prepare deterministic preflight SQL and rollback notes only after the above is reconciled.

## Safety boundary

This document is a review artifact. No production data or schema was modified. Do not merge, deploy, apply migrations, change active n8n workflows, update the Worker, or release a Shopify app without separate explicit authorization.
