# HENVALT app-identity and store-boundary database contract

Status: design only, not an executable migration. Prepared from read-only inspection of the live Supabase schema, RPC definitions, and deployed Edge Functions on 2026-11-16. Do not apply this document to production.

## 1. Design goals

- Keep the current merchant-owned Shopify app operational as the legacy app.
- Prepare a separate Partner-owned public app without replacing legacy credentials or app identity.
- Preserve tenant isolation and current Supabase Vault token storage.
- Support multiple Shopify stores under one tenant.
- Prevent a second app identity from overwriting another app's OAuth state, token pair, connection, webhook verification, or uninstall lifecycle.
- Make the distinction between store-scoped data and tenant-shared configuration explicit.
- Fail closed when app identity, store selection, tenant membership, or data ownership is ambiguous.

## 2. Existing invariants that must not be broken

1. `shopify_connections.shop_domain` is currently unique. Keep this uniqueness during the first public-app rollout if the product policy remains one active HENVALT app identity per Shopify shop. This avoids same-shop legacy/public collision while allowing different shops under one tenant to use different app identities.
2. `shopify_connections` already allows multiple rows per tenant; live read-only inspection found a tenant with two active connections. Never introduce a one-connection-per-tenant constraint.
3. `shopify_connections` has tenant-isolation RLS. Preserve its policy.
4. `shopify_oauth_states` has RLS enabled and no ordinary row policy. Keep OAuth-state writes and reads behind trusted service-role/RPC code; do not add authenticated-user table access.
5. Shopify access/refresh tokens are stored as Vault secret references. Continue storing references, never plaintext token values, in ordinary tables.
6. Pixel keys reference an exact `shopify_connection_id`; preserve this exact connection binding.
7. MailerSend provider credentials are tenant/provider resources and must not be mixed with Shopify app secrets.
8. Existing legacy secret references and OAuth installations must remain valid through an additive, reversible rollout.

## 3. Proposed app registry

Create a private registry table in the `henvalt` schema, not exposed to ordinary client roles.

Conceptual fields (names are proposals, not migration SQL):

| Field | Purpose |
|---|---|
| `app_key` | Stable internal identifier, e.g. `legacy`, `public_v1`; never a Shopify client ID |
| `shopify_client_id` | Shopify app client ID; unique |
| `secret_vault_name` | Name/reference of the app's Shopify secret in Vault |
| `active` | Allows safe activation/deactivation without deleting identity history |
| `distribution_type` | Internal/merchant-owned/public; operational metadata only |
| `created_at`, `updated_at` | Auditability |

Security requirements:
- The registry must not contain plaintext Shopify app secrets.
- Only trusted server-side functions/service role may read app configuration and resolve Vault secrets.
- Never expose app registry rows or Vault secret references to browser clients.
- Do not let callers choose an arbitrary Vault secret name; app key must resolve through a fixed, trusted registry row.

## 4. OAuth state and connection binding

Add an app identity reference to OAuth state and each Shopify connection.

- `shopify_oauth_states.app_key`: required for new flows; written at install initiation and read back during callback.
- `shopify_connections.app_key`: required after legacy backfill; identifies which HENVALT app owns the connection.
- OAuth state consumption, tenant ownership validation, connection creation/update, and Vault token-reference persistence must happen atomically or through an idempotent transaction boundary.
- Callback must use the app key stored in the one-time state to choose client ID and secret. Never choose credentials from callback parameters, shop headers, or an unsigned request field.
- Refresh claim must return the connection's immutable app key along with the correct refresh-token reference. Complete/fail operations must be bound to the same connection/app key and refresh lease generation.
- Keep current `shop_domain` unique constraint for first rollout. Reject same-shop installation from a different app key with a clear conflict response; never overwrite the existing connection.
- Preserve existing legacy token Vault references during backfill. Do not rename or rotate them merely to fit the new naming convention.

## 5. Webhook identity contract

- Each app has an explicit ingress route mapped to a fixed app key by server configuration.
- Worker chooses the secret from the trusted app registry, verifies HMAC over the exact raw request bytes, then forwards the verified app key internally.
- Strip any caller-supplied copy of the internal app-key header before setting the trusted value.
- n8n must pass app key, original HMAC, and raw-body base64 to an app-aware Supabase verifier.
- Supabase independently checks that the app is active, verifies HMAC with that app's Vault secret, and resolves the connection by app key plus shop domain.
- Unknown/inactive app key, wrong app/shop pairing, malformed HMAC, and mismatched connection must fail closed. No fallback to the legacy secret.
- OAuth webhook registration, privacy subscriptions, and uninstall events must use the same app-specific route.

## 6. Store-scoped versus tenant-scoped data

The database and deployed functions currently mix these scopes. The following is the proposed default contract; each exception must be deliberate and documented.

| Resource | Proposed scope | Reason |
|---|---|---|
| Shopify app registry / app secret | App | One credential set per Shopify app |
| OAuth state | App + shop + one-time state | Callback must recover exact initiating app |
| Shopify connection / Admin API tokens | Store connection | Credentials belong to one shop installation |
| Shopify webhook identity | App + store connection | HMAC and tenant routing need exact app/shop pair |
| Pixel key | Store connection | Existing exact connection FK already provides this |
| Opportunity / checkout / order / attribution / revenue event | Store connection, plus tenant | Prevent one store's event from appearing as another store's recovery |
| Dashboard activity and revenue series | Store connection by default | Merchant dashboard is entered for a specific shop |
| Tenant membership and authorization | Tenant | User can be authorized for multiple stores in a tenant |
| MailerSend provider configuration | Tenant/provider by default | Provider credential is not a Shopify app credential |
| Sender profile, brand identity, recovery flow preferences | Explicit product choice; default store-scoped for separate independent shops | Existing writes are tenant-level and can unintentionally affect all shops |
| Billing subscription / usage charges | Store connection by default for Shopify-native billing; tenant roll-up for reporting | Shopify subscriptions are installed/managed per shop; exact billing policy and provider must be confirmed before migration |

If the business later chooses tenant-wide shared billing or settings, the API and dashboard must label those resources as tenant-wide. Do not present tenant-wide totals as store-specific values.

## 7. Required data model additions

Before writing migration SQL, inspect all constraints and foreign keys and determine whether to add explicit `shopify_connection_id` columns to Shopify-originated records, including opportunities, checkouts, orders/attributions, and revenue-ledger entries.

Do not rely solely on `metadata->>'shop_domain'` for long-term referential integrity. Metadata may remain for diagnostics, but store ownership should use a foreign key to the connection. Backfill only when an existing row can be mapped unambiguously; quarantine or leave unresolved rows requiring review rather than guessing.

For billing, determine whether existing measurements can be mapped to a store from their linked ledger/opportunity/order. Never attach an ambiguous tenant-level measurement to an arbitrary shop.

## 8. Required RPC/API contract changes

At minimum, review and update these families together:

- OAuth lifecycle: state creation/consumption, owner finalization, connect, disconnect, app state.
- Token lifecycle: refresh claim, completion, failure, Admin API token retrieval.
- Webhook lifecycle: HMAC verification, tenant/connection resolution, uninstall deactivation, privacy request handling.
- Control plane: dashboard summary, revenue series, settings, sender profile, billing summary/sync/status/usage claim/result.
- Recovery: candidate selection for cart/checkout/browse, delivery authorization, recovery context, next intervention scheduling, Shopify order/checkout lookup.
- Pixel: provisioning, ingestion, revocation.
- Merchant Edge Functions: dashboard, sender profile, recovery settings, email branding, and any other endpoint that resolves a user to a shop.

Avoid a partial rollout where Worker, n8n, Supabase verifier, OAuth, or refresh uses a different app identity contract.

## 9. Merchant store-selection contract

- Authenticate the Supabase user through Auth.
- Resolve all tenant memberships the user is authorized for.
- Return only active Shopify connections in those tenants.
- If one connection exists, it may be selected automatically.
- If multiple connections exist, require an explicit selection; do not return 403 merely because there is more than one and do not select the first row.
- Persist or pass the selected connection identifier in a server-validated way. Re-check that the connection belongs to one of the user's authorized tenants on every request.
- Never trust a raw client-supplied shop domain as proof of membership.
- For the control-plane service token, keep it server-only and bind internal authorization to the verified app identity and authorized connection, not just a global token plus caller-supplied shop header.

## 10. Rollout sequence (design only)

1. Freeze the legacy behavior contract and capture regression tests.
2. Add app registry and nullable app-key columns; backfill existing app connections and OAuth state history as `legacy` only where unambiguous.
3. Add app-aware RPCs alongside legacy wrappers. Legacy wrappers must be restricted to the legacy app and must fail closed if resolution is ambiguous.
4. Update OAuth install/callback and token refresh as a matched release.
5. Update Worker route/secret selection, n8n trusted app-key propagation, and Supabase HMAC/tenant resolver as one ingress release.
6. Update privacy and uninstall routes.
7. Update merchant store selection, dashboard scoping, recovery settings, sender profile, and branding APIs.
8. Update recovery candidate/event attribution to exact connection IDs; backfill only deterministic rows.
9. Decide and implement store-level billing or explicitly shared tenant billing, including subscription idempotency and reporting.
10. Run the complete regression matrix in an isolated environment, then request separate authorization for production rollout and Shopify app distribution.

## 11. Mandatory regression matrix

- Legacy install/callback/refresh/webhook/privacy/uninstall remains functional.
- Public app install/callback/refresh/webhook/privacy/uninstall uses only its own secret.
- Tampered HMAC, wrong app key, unknown app key, inactive app, mismatched app/shop, and spoofed internal header are rejected.
- Existing shop connection cannot be overwritten by another app.
- Two different stores in one tenant resolve to different connection IDs and never mix recovery events, revenue, dashboard activity, or credentials.
- Merchant user with multiple active stores can explicitly select each store; unauthorized store selection is rejected.
- Tenant-wide settings (if retained) are clearly shared; store-specific settings do not leak across stores.
- Uninstall one store does not deactivate another store, revoke its pixel key, or cancel shared billing while another eligible connection remains.
- Pixel key remains bound to exact connection.
- Checkout/cart/browse recovery, consent, suppression, delivery idempotency, attribution, and billing measurement regressions pass.
- No Shopify secret, access token, refresh token, service-role key, or control-plane token appears in client bundles, logs, or ordinary DB columns.

## 12. Explicit non-actions

This document is not executable SQL and is not an approval to change production. No database migration has been applied. No live function, secret, RLS policy, n8n workflow, Cloudflare Worker, Shopify app, or billing configuration has been changed. The current PR remains a draft preparation artifact.


## 13. Confirmed relationship, uniqueness, and workflow audit (2026-11-16)

The following points were verified against the live `henvalt` schema using read-only catalog queries and against the current active n8n workflow definitions. This section records observed facts, not proposed live changes.

### 13.1 Shopify-originated records are currently tenant-bound, not connection-bound

The inspected tables have tenant foreign keys, but no direct `shopify_connection_id` foreign key:

- `webhook_events`: `tenant_id` only; unique keys include `(tenant_id, idempotency_key)` and `(tenant_id, source, source_event_id)`.
- `canonical_events`: `tenant_id` and optional `webhook_event_id`; unique `(tenant_id, idempotency_key)`.
- `customers`: `tenant_id`; unique `(tenant_id, shopify_customer_id)`.
- `checkouts`: `tenant_id`, optional `customer_id`; unique `(tenant_id, shopify_checkout_id)`; also unique partial `(tenant_id, checkout_token)`.
- `opportunities`: `tenant_id`, optional FKs to `source_event_id`, `customer_id`, and `checkout_id`; unique `(tenant_id, idempotency_key)`.
- `recovery_sequences` and `recovery_interventions`: tenant and opportunity/sequence relationships; no direct store-connection FK.
- `orders`: `tenant_id`, optional customer and checkout FKs; unique `(tenant_id, shopify_order_id)`.
- `order_attributions`: `tenant_id`, FKs to order/opportunity/recovery/intervention; unique `(tenant_id, order_id)`.
- `revenue_ledger`: `tenant_id`, FKs to order/attribution/opportunity/recovery; recovery uniqueness is tenant/order scoped.
- `delivery_requests` and `delivery_attempts`: tenant and recovery/intervention relationships; no direct store-connection FK.

This means two stores belonging to one tenant can collide on Shopify customer, checkout, order, event, and idempotency keys where Shopify IDs or source IDs overlap. A `shop_domain` metadata field is not a database-enforced ownership boundary. New store binding must be carried by a real connection FK and the relevant uniqueness keys must be reviewed to include that connection identity (or an equivalent store-specific natural key).

### 13.2 Billing and provider resources are tenant-scoped in the current schema

- `billing_accounts` primary key is `tenant_id`; Shopify provider subscription ID is separately unique. It cannot represent two independent Shopify billing subscriptions for two stores in one tenant.
- `billing_measurements` references tenant, billing period, and optional revenue-ledger row; it has one-per-ledger-entry uniqueness by tenant/ledger entry. A measurement linked to a ledger row can inherit store ownership only after that ledger row is deterministically mapped.
- `billing_usage_charges` references tenant and measurement; unique by tenant/idempotency key and one charge per measurement.
- `email_usage_measurements` references a delivery attempt and tenant; provider cost attribution should follow the delivery attempt's store binding if/when store-level reporting is required.
- `provider_configs` and `sending_identities` are tenant-level; sending identity references provider config. This matches the current MailerSend tenant/provider design and should not be coupled to Shopify app secrets.
- `pixel_keys` are the strong exception: each key has an explicit FK to `shopify_connections(id)`, plus tenant FK, and an index on connection/active state. Preserve this design.

### 13.3 Existing uniqueness/index implications

Observed tenant-scoped unique constraints/indexes include:
- canonical events: tenant + idempotency key;
- customers: tenant + Shopify customer ID;
- checkouts: tenant + Shopify checkout ID, and tenant + checkout token;
- opportunities: tenant + idempotency key;
- orders: tenant + Shopify order ID;
- order attributions: tenant + order ID;
- revenue ledger: one recovery per tenant/order and adjustment uniqueness using tenant plus order/source-event metadata;
- delivery requests: tenant + idempotency key;
- webhook events: tenant + idempotency key and tenant + source + source-event ID.

Do not simply add `shopify_connection_id` columns while leaving these unique constraints unchanged. Otherwise store-specific rows may still conflict or be silently treated as duplicates. Review each idempotency key's semantics and migrate constraints with compatibility wrappers and collision tests. Do not drop constraints until replacement constraints and old-client behavior are covered.

### 13.4 Verified n8n ingest identity path

The active `HENVALT_INGEST` workflow currently:
1. `Validate & Normalize` extracts `x-shopify-shop-domain` and Shopify HMAC from headers, preserves raw-body base64, and normalizes the event.
2. `Verify Shopify HMAC` calls the legacy `verify_shopify_webhook_hmac(p_hmac, p_raw_body_base64)` RPC. There is no app key in this call.
3. `Resolve Shopify Tenant` calls `resolve_shopify_tenant(p_shop_domain)`.
4. `Bind Tenant Context` binds only the returned tenant UUID. It does not bind a connection ID or app key.
5. Customer, checkout, canonical event, and opportunity RPCs receive tenant IDs and some metadata containing `shop_domain`; the primary key/idempotency contract remains tenant-scoped.
6. Order projection, attribution, and ledger posting are invoked by event/order/attribution IDs, with no app-key or connection-ID argument in the workflow calls inspected.

This confirms the identity gap exists in the active workflow, not just in a proposed future workflow. It also means the correct change must be coordinated with the Supabase RPCs and uniqueness model; a workflow-only metadata addition is insufficient.

### 13.5 Verified n8n recovery and delivery identity path

- `HENVALT_RECOVERY` selects expiring Shopify connections by shop domain and calls the legacy token-refresh Edge Function with `shop_domain` only. The token-refresh lifecycle therefore needs app identity and connection/lease binding as a coordinated contract.
- `HENVALT_DELIVERY` authorizes a delivery request using tenant, delivery/intervention/recovery/opportunity IDs and idempotency key. This is appropriate for the email provider operation only if those records already carry a trusted store FK and the authorization RPC verifies the entire relationship.
- Delivery scheduling calls `schedule_next_recovery_intervention(p_delivery_request_id)`; it must continue from the delivery request's owning opportunity/connection rather than re-resolving an arbitrary active store in the tenant.
- MailerSend credential lookup remains tenant/provider-scoped; it must not be switched to Shopify app-key scope.

### 13.6 Migration and rollout consequence

The minimum coherent data migration must cover the event-to-recovery lineage, not only `shopify_connections`:

`webhook_events → canonical_events → customers/checkouts → opportunities → recovery_sequences/recovery_interventions → delivery_requests/attempts → orders → order_attributions → revenue_ledger → billing_measurements/usage charges`.

The exact tables requiring direct `shopify_connection_id` columns, composite uniqueness, or derived ownership must be decided per table after reviewing all writers/readers and existing rows. Child rows may inherit ownership through a required parent FK only if every relevant RPC enforces same-tenant and same-connection consistency. Where direct FK is useful for query performance or security predicates, it must be maintained transactionally and checked against the parent.

Before producing executable migration SQL, complete:
1. full writer/reader inventory for every table in this lineage;
2. exact row-level backfill classification (deterministic, ambiguous, or missing);
3. constraint migration design preserving existing idempotency;
4. tenant-scoped settings/billing policy decision;
5. RPC compatibility plan for active n8n and deployed Edge Functions.

No migration SQL is included here yet. No live database, workflow, Edge Function, Worker, secret, or Shopify configuration was changed during this audit.


## 14. Writer-function and existing-row backfill findings (2026-11-16)

### 14.1 Current writer RPCs do not enforce store identity

Read-only inspection of the deployed function definitions confirmed:

- `upsert_customer(p_tenant_id, p_shopify_customer_id, ... p_metadata)` searches by `tenant_id + shopify_customer_id`; when no Shopify customer ID is supplied, it can fall back to `tenant_id + normalized email`. The supplied metadata (which may contain `shop_domain`) is not part of the lookup identity. Two stores in one tenant can therefore resolve to the same customer row.
- `upsert_checkout(p_tenant_id, p_shopify_checkout_id, ..., p_metadata)` accepts tenant and metadata but has no connection ID argument. Its table uniqueness is tenant + Shopify checkout ID (and tenant + checkout token), not store-specific.
- `upsert_canonical_event` accepts tenant and metadata but no connection ID; its idempotency lookup is tenant + idempotency key.
- `create_opportunity_idempotent` accepts tenant, event/customer/checkout IDs and an idempotency key, but no connection ID or store metadata parameter. It verifies that customer and checkout belong to the tenant, then uses tenant + idempotency key and tenant + checkout for cycle handling.
- The active ingest workflow therefore cannot repair this by adding a shop-domain metadata field alone. The writer RPCs, table keys, and downstream readers must change together.

### 14.2 Existing sample data classification (not representative traffic metrics)

A read-only count of current rows and presence of `metadata.shop_domain` returned:

| Table | Rows | With shop domain | Without shop domain |
|---|---:|---:|---:|
| `webhook_events` | 132 | 130 | 2 |
| `canonical_events` | 166 | 130 | 36 |
| `customers` | 3 | 2 | 1 |
| `checkouts` | 2 | 1 | 1 |
| `opportunities` | 5 | 3 | 2 |
| `orders` | 0 | 0 | 0 |
| `order_attributions` | 0 | 0 | 0 |
| `revenue_ledger` | 0 | 0 | 0 |

These are the current database contents only, not production-volume or product-performance metrics. The sample proves that metadata-only backfill cannot be assumed complete: some existing canonical events, customers, checkouts, and opportunities lack a shop-domain marker. Orders/attribution/revenue currently have no rows to backfill in this snapshot, but their future writers still need connection identity.

### 14.3 Safe backfill rules

- Backfill a row to `shopify_connection_id` only if its direct trusted source event, checkout, order, or parent relationship resolves to exactly one connection in the same tenant.
- A `metadata.shop_domain` value may be used as a candidate mapping key only after checking that exactly one connection in the same tenant matches it and that the record's source lineage agrees.
- A row with no shop-domain marker, multiple plausible connections, or conflicting parent/source store identities is unresolved. Leave it null/quarantined for review; never infer the store from the tenant's only currently active connection, because the number of active connections can change.
- Customer identity requires an explicit product decision: customer records should be store-scoped for Shopify IDs and consent state, while any tenant-wide cross-store contact deduplication must be a separate, deliberate identity layer. Do not merge Shopify customer IDs across stores merely because email addresses match.
- Before adding NOT NULL or composite constraints, inventory all writers and resolve all existing null/ambiguous rows. The current sample is too small to justify assumptions about future completeness.

### 14.4 Additional recovery isolation checks required

The inspected `authorize_delivery_request` validates tenant ownership across delivery request, intervention, sequence, opportunity, customer, and message. For cart/browse/checkout paths it also checks an active connection using `metadata.shop_domain` in several branches. However, the order-paid checks and cart-to-checkout advancement checks include tenant/customer predicates without a consistent exact connection predicate. Once direct connection FKs exist, these checks must compare the same connection ID across the opportunity, checkout, order, and active Shopify connection. Otherwise a purchase in Store A could suppress recovery in Store B when a tenant shares customer identity or customer IDs.

The recovery candidate functions and order attribution functions must receive the same treatment. Store identity must be preserved through all eligibility, conversion-stop, and attribution decisions—not only at initial webhook ingestion.

No backfill, schema change, function replacement, or workflow edit was performed.


## 15. Conversation, consent, and current deployed function boundary (2026-11-16)

### 15.1 Reply/conversation lineage inherits customer and delivery ownership

The current reply pipeline is:
`delivery_request → customer_conversation → conversation_messages`.

Observed constraints:
- `customer_conversations` has tenant FK and references customer, delivery request, intervention, opportunity, and recovery; it has a unique tenant/delivery-request key and a tenant/id composite key.
- `conversation_messages` has tenant FK, a composite FK to `customer_conversations(tenant_id,id)`, and a unique provider event ID.
- `email_usage_measurements` references the exact delivery attempt; delivery attempts reference the exact delivery request.
- These parent relationships are useful tenant integrity, but none of the conversation records directly carries a Shopify connection ID.

The active `HENVALT_DELIVERY` inbound-reply path calls `process_mailersend_inbound_reply(payload, raw_body_base64)`, then loads AI context by conversation/message IDs. The context query joins the customer and tenant, and reads tenant-level store name, reply-AI setting, and knowledge base. Conversation history is selected by the conversation and its original delivery request.

Design consequence:
- Keep the conversation bound to its originating delivery request and recovery lineage.
- If a customer row is store-scoped, conversation ownership follows that customer and originating opportunity/connection.
- AI reply context must use the originating store's approved identity/knowledge base if settings become store-specific; do not silently use another store's tenant settings.
- Human-required and opted-out states must continue to block automated replies. This audit did not alter any reply behavior.

### 15.2 Consent is especially sensitive to customer identity scope

The ingest workflow's `Upsert Customer` call sends email, phone, marketing consent, SMS consent and consent-source metadata to `upsert_customer`; the supplied metadata includes `shop_domain`, but the current lookup key is not store-specific. The separate consent-update event path also resolves the customer in the tenant context.

Shopify customer consent must be scoped to the correct shop/customer identity. A tenant-wide email fallback can join two different Shopify customer records and potentially carry consent or suppression state between stores. The revised customer contract must therefore:
- key Shopify customer IDs by connection/store;
- preserve consent provenance and timestamps per store;
- avoid treating a matching email as proof that two store-specific Shopify customer records are the same legal/consent identity;
- if HENVALT later supports tenant-wide cross-store contact suppression, implement it as an explicit conservative suppression layer, not by merging source customer rows.

### 15.3 Current deployed Shopify Edge Functions: confirmed legacy-only identity

Read-only retrieval of deployed Edge Function source confirms:

- `henvalt-shopify-oauth` v27 reads one `SHOPIFY_API_KEY` and one `SHOPIFY_API_SECRET`; OAuth state and callback are not app-key aware.
- `henvalt-shopify-token-refresh` v1 reads the same single key/secret pair and calls refresh claim/fail/complete RPCs with shop domain only.
- `henvalt-shopify-privacy` v1 verifies with one `SHOPIFY_API_SECRET`, then looks up `shopify_connections` by shop domain. It cannot distinguish two app registrations.
- `henvalt-control-plane` v24 uses the shared server-side control-plane bearer and shop-domain RPC arguments; the app identity is not part of its authorization context.
- `henvalt-pixel-ingest-proxy` v3 forwards the pixel key digest and collector secret to `henvalt_ingest_pixel_event`; the database maps the pixel key to its exact connection ID. Preserve this binding.
- Merchant dashboard, sender profile, recovery settings and email branding functions authenticate the Supabase user, then require exactly one tenant membership and exactly one active shop connection. Multi-store users are rejected rather than being given a store selector.
- Email branding and reply-AI settings are read/written through tenant settings in the inspected functions. This is a deliberate scope decision still required for product design: either tenant-wide shared defaults with per-store overrides, or fully store-scoped settings. The API must state which.

No Edge Function code or secret was changed.

### 15.4 Current n8n lineage and gaps, verified from active workflow definitions

The active workflow versions were read without executing them:

- `HENVALT_INGEST` version `6368d539-708f-494a-8be8-b9601d0e8607`: verifies the webhook with `verify_shopify_webhook_hmac(p_hmac,p_raw_body_base64)`, resolves via `resolve_shopify_tenant(p_shop_domain)`, and binds only `tenant_id`. Its customer, checkout, opportunity, order projection, attribution, recovery-stop and ledger calls do not receive a connection ID.
- `HENVALT_RECOVERY` version `32e50bf7-4cbd-4070-bbba-f259ed17b369`: discovers browse/cart/checkout candidates through tenant-level candidate RPCs; refreshes tokens by `shop_domain`; obtains recovery context from intervention ID; creates delivery requests from intervention/message/customer data.
- `HENVALT_DELIVERY` version `621ae6ce-a006-4fed-a70e-acf774c360fb`: authorizes delivery with tenant, delivery, intervention, recovery, opportunity, recipient and idempotency values. It schedules the next step by delivery request ID. Its inbound reply AI context uses tenant settings as noted above.

These versions are active and unchanged. A safe migration must update the RPC contracts and workflow payloads in a coordinated, backwards-compatible sequence; do not partially add app identity to only one workflow.

### 15.5 Revised rollout gates

Before writing executable migration SQL, close these remaining gates:
1. Inventory every writer and reader of the event-to-ledger lineage, including scheduled candidate discovery and conversion-stop queries.
2. Inventory all consent update, unsubscribe, inbound reply, and AI-context readers/writers to decide the customer/contact scope safely.
3. Decide tenant-shared defaults versus store-specific overrides for sender profile, email branding, recovery settings, AI reply knowledge, and billing.
4. Define connection-aware RPC signatures and compatibility wrappers for currently active workflow versions.
5. Define a deterministic migration/backfill report with separate counts for mapped, ambiguous, missing, and conflicting records.
6. Define tests that prove Store A events, orders, consent, replies, dashboards and billing cannot affect Store B, while preserving tenant membership and shared provider credentials where intended.

No executable migration file is included yet. This is intentional: the writer/reader and settings-scope decisions above are prerequisites, not implementation details to guess.
