# Store-aware Shopify Pixel Writer — V2 Implementation Contract

**Status:** implementation contract derived from live source and catalog inspection; no production change.  
**Inspection date:** 2026-11-16  
**Target:** replace the tenant-only identity behavior of `henvalt.ingest_pixel_event` through a separately versioned V2 path after all dependent writers are ready.

## 1. Live source facts confirmed

The deployed `henvalt.ingest_pixel_event(p_key_digest text, p_origin text, p_payload jsonb)` currently:

1. Resolves `pixel_keys.key_digest` against `pixel_keys.shopify_connection_id`, matching tenant, active connection, active/unrevoked key, allowed origin and active tenant.
2. Selects only `pk.tenant_id` into its local identity variable; the exact connection is discarded.
3. Calls the legacy `henvalt.upsert_canonical_event(...)` with idempotency key `shopify-pixel:<event_id>`.
4. Calls `henvalt.resolve_identity(event_id)`, whose customer, email, session, alias and checkout lookups are tenant-scoped.
5. May call `henvalt.bind_session_alias(tenant_id, checkout_reference, client_id)`, also tenant-scoped.

The deployed helper signatures are:

- `upsert_canonical_event(p_tenant_id uuid, p_webhook_event_id uuid, p_event_type text, p_event_class henvalt.event_class, p_source text, p_source_event_id text, p_customer_reference text, p_email text, p_anonymous_reference text, p_session_reference text, p_occurred_at timestamptz, p_value_at_risk numeric, p_currency character, p_payload jsonb, p_metadata jsonb, p_idempotency_key text, p_correlation_id uuid)`
- `resolve_identity(p_event_id uuid)`
- `bind_session_alias(p_tenant_id uuid, p_alias_reference text, p_session_reference text)`
- `upsert_customer(p_tenant_id uuid, p_shopify_customer_id text, p_email text, p_phone text, p_first_name text, p_last_name text, p_email_consent boolean, p_whatsapp_consent boolean, p_sms_consent boolean, p_metadata jsonb)`
- `upsert_checkout(p_tenant_id uuid, p_shopify_checkout_id text, p_customer_id uuid, p_checkout_token text, p_session_reference text, p_email text, p_total_value numeric, p_currency character, p_status text, p_metadata jsonb)`

## 2. V2 trust boundary

Create new, versioned database functions; do not silently replace V1 signatures:

- `henvalt.ingest_pixel_event_v2(p_key_digest, p_origin, p_payload)`
- `henvalt.upsert_canonical_event_v2(..., p_shopify_connection_id uuid, ...)`
- `henvalt.resolve_identity_v2(p_event_id uuid)`
- `henvalt.bind_session_alias_v2(p_tenant_id uuid, p_shopify_connection_id uuid, p_alias_reference text, p_session_reference text)`

The browser must never supply the authoritative tenant ID, connection ID or app key. V2 derives them from the stored pixel-key row joined to the exact connection and active tenant. Require exactly one matching active key/connection/origin tuple; reject missing, inactive, revoked or conflicting relationships.

## 3. Required schema and writer ordering

Before V2 can safely accept events that may collide with another store, the migration series must establish connection lineage and connection-aware identity semantics for:

1. `canonical_events`
2. `customers`
3. `sessions`
4. `session_aliases`
5. `checkouts`

The writer must use the exact connection for every lookup, insert, conflict target and update. It must never use email as a cross-store identity key. Session aliases must be scoped by (tenant, connection, alias). Checkout lookup must include connection before comparing checkout ID, token, email or session.

**Critical migration ordering:** current live unique constraints are tenant-only for customer Shopify ID, checkout Shopify ID, session reference, session alias, and canonical event idempotency. Adding connection columns and new composite indexes does not neutralize those old unique constraints. Dropping them before all legacy writers are migrated would break their existing ON CONFLICT targets or weaken their behavior. Therefore:

- Do not enable V2 writes that require duplicate same-tenant external IDs across stores until every affected writer has been inventoried and migrated.
- Keep V2 behind a disabled feature flag while the migration series is incomplete.
- Use a later, separately reviewed cutover migration to replace tenant-only uniqueness only after all legacy writers have safe V2 replacements or a compatibility adapter.
- Do not backfill historical connection IDs from metadata, email, current pixel keys, tenant membership, origin, event time or reused external IDs.
- Historical rows with no immutable provenance remain unresolved and excluded from store-specific recovery and billing.

## 4. Atomic event behavior

Within one database transaction, V2 must:

1. Validate the same event schema, type allow-list, input lengths, timestamp bounds and request-size limits as V1.
2. Resolve and lock the exact active pixel key + connection + tenant.
3. Apply rate limiting using the pixel key digest as today.
4. Insert a canonical event carrying the exact connection ID.
5. Use a connection-qualified idempotency key, e.g. `shopify-pixel:<connection_uuid>:<event_id>`.
6. Resolve customer/session/checkout only inside that connection.
7. Bind checkout/cart aliases only inside that connection.
8. Return accepted/duplicate and an opaque event ID; do not return tenant or connection identifiers to the storefront.

If the V2 identity resolver cannot prove a single connection-scoped match, it must leave the relevant identity unresolved or reject the operation. It must not fall back to V1 tenant-wide resolution.

## 5. Required two-store integration cases

A disposable PostgreSQL integration fixture must create two active connections under one tenant and intentionally reuse external identifiers:

- Same pixel event ID in Store A and Store B produces two distinct canonical events.
- Repeating the same event ID within Store A is idempotent.
- Same Shopify customer ID in A and B resolves to distinct customer rows.
- Same normalized email in A and B never attaches A's event to B's customer.
- Same client/session reference in A and B resolves to distinct sessions.
- Same checkout/cart alias in A and B remains store-scoped.
- Checkout token/ID in B is never returned for A.
- Revoked key, inactive connection, inactive tenant, wrong origin and mismatched key/connection tenant all reject before event insertion.
- Browser-supplied tenant/connection/app fields cannot override the key-derived identity.
- Analytics consent disabled never triggers a customer identity fallback.
- A webhook-originated event must inherit the exact connection from its verified inbox receipt; a caller-supplied mismatch rejects.

## 6. Downstream gate

A connection-aware pixel writer alone does not make the recovery system multi-store safe. Candidate discovery, opportunity creation, recovery worker context, delivery authorization, conversion-stop logic, unsubscribe/consent, attribution, billing and exact-store privacy must all enforce the same connection lineage.

Until those downstream paths are migrated and tested, V2 pixel events must not enter recovery, delivery, attribution or billing queues. The verified webhook inbox remains a durable inbox, not a completed recovery pipeline.

## 7. Explicit non-actions

This contract is not an executable migration and does not alter the live function. No production DDL/DML, backfill, function replacement, feature-flag change, Worker/Edge deployment, n8n edit, Shopify setting or release occurred.
