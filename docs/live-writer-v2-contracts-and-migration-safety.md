# Live writer semantics and safe v2 migration requirements

Status: read-only audit of deployed PostgreSQL function definitions, 2026-11-16. Design handoff only; no production function was replaced.

## Functions inspected

The deployed function catalog returned one overload each for:
- `upsert_customer(uuid,text,text,text,text,text,boolean,boolean,boolean,jsonb)`
- `upsert_checkout(uuid,text,uuid,text,text,text,numeric,character,text,jsonb)`
- `upsert_canonical_event(...)`
- `project_order_from_event(uuid)`

## 1. `upsert_customer`: tenant-only identity merge

Verified body flow:
1. Selects a customer where `tenant_id = p_tenant_id` and either:
   - supplied Shopify customer ID matches; or
   - Shopify customer ID is null and lowercased email matches.
2. Orders matches by `created_at ASC` and takes the first.
3. If absent, inserts customer with tenant ID and supplied profile/consent fields.
4. If found, updates that row, coalescing profile and consent fields and merging metadata.

No connection ID participates in the lookup, insert, or update.

**V2 contract**
- Require trusted connection ID from the authenticated event envelope.
- Resolve only within `tenant_id + shopify_connection_id`.
- Shopify customer ID matching is scoped to the connection.
- Email fallback is scoped to the connection and only used under explicit fallback rules.
- If the supplied customer UUID already belongs to another tenant or connection, reject; never reparent it.
- Do not merge customers across stores based solely on equal email.
- Preserve consent per store unless an explicit, documented tenant-wide preference is separately recorded.

## 2. `upsert_checkout`: tenant-only conflict target

Verified body inserts into `henvalt.checkouts` and uses:
`ON CONFLICT (tenant_id, shopify_checkout_id) DO UPDATE`.

The update branch refreshes checkout fields on the conflicting tenant-level row. It has no connection ID in the function signature.

**V2 contract**
- Add a v2 writer that requires exact trusted connection ID.
- Validate the customer reference belongs to the same tenant and connection before insert/update.
- Conflict identity must be scoped to the connection after the matching unique index exists.
- Checkout-token uniqueness and matching must also be connection-scoped.
- Do not change the existing unique index or existing writer until compatibility dual-write/read-compare and collision review pass.
- The old function remains legacy-only; never silently call it for public-app traffic.

## 3. `upsert_canonical_event`: tenant-only idempotency lookup

Verified body:
1. Selects existing canonical event by `tenant_id = p_tenant_id AND idempotency_key = p_idempotency_key`.
2. If found, returns that event as a duplicate without checking source event or store identity.
3. Otherwise inserts tenant, webhook reference, source identifiers, customer/session references, payload, metadata and idempotency key.
4. Function signature has no connection ID.

**V2 contract**
- Connection identity must be inherited from a verified webhook receipt or active pixel key, never trusted from arbitrary payload metadata.
- Duplicate lookup and uniqueness must use connection namespace.
- If webhook receipt is present, its tenant and connection must match the v2 arguments; mismatch is a hard reject.
- Replayed key from another store must not resolve to an event in the first store.
- Preserve a safe legacy path for existing traffic while new app traffic uses v2.

## 4. `project_order_from_event`: tenant-only order/customer/checkout joins

Verified body:
1. Loads tenant ID and payload from canonical event by event UUID.
2. Finds existing order by tenant ID + Shopify order ID.
3. Resolves customer by tenant ID and either lowercased email or Shopify customer ID, preferring matching Shopify customer ID, then newest row.
4. Resolves checkout by tenant ID + Shopify checkout ID.
5. Updates existing order or inserts a new order; order row stores source event ID in metadata on insert, and last event ID on update.
6. Function signature accepts only event UUID and derives no typed connection ID.

**V2 contract**
- Load the canonical event's trusted connection ID.
- Require customer and checkout to share exact tenant+connection before linking.
- Existing order lookup must include connection identity.
- Store a typed source-event reference/connection relationship, not only JSON metadata.
- If an existing order ID is associated with a different connection, reject and emit an audit event; never update it.
- Do not allow a missing/ambiguous event connection to fall back to a tenant-wide lookup.

## 5. Required migration mechanics

### Additive stage
- Add a unique referenced key for `shopify_connections(tenant_id,id)`.
- Add nullable `shopify_connection_id` columns to source tables first, then derived tables.
- Add composite FKs with carefully selected delete semantics after orphan checks.
- Do not automatically backfill old rows from `metadata.shop_domain`, email, customer IDs, timestamps or currently active connection counts.
- Existing ambiguous rows remain null and are marked legacy-only/quarantined by explicit operational policy.

### Writer stage
- Introduce separate v2 function signatures. Do not mutate legacy function semantics in place while old Worker/n8n workflows may still call them.
- Require service-to-service authenticated identity envelope and exact connection ID.
- For every passed tenant/customer/checkout/event/order UUID, re-read and verify tenant+connection equality inside the same transaction.
- Revoke public/anon/authenticated execution as appropriate; grant only intended service role and keep explicit RLS/security-definer review.
- Use deterministic connection-scoped idempotency keys and matching unique indexes only after duplicate collision checks.

### Cutover stage
1. Deploy app-aware ingress and v2 writers together in a controlled non-production environment.
2. Dual-write only for events whose app identity and connection are verified.
3. Compare old/new resolution results in shadow mode; do not let old cross-tenant/store matches authorize a send or charge.
4. Run synthetic fixtures with same customer ID, email, checkout ID/token, session ID, order ID and idempotency key across two stores in one tenant.
5. Switch readers and workers only after zero cross-connection matches and all regression cases pass.
6. Create/validate connection-scoped unique indexes; then switch v2 conflict targets.
7. Keep rollback to legacy-only behavior for legacy app traffic, never route public-app events through tenant-only legacy writers.

## 6. Exact blockers before executable SQL

- Full schema inventory for all affected columns and existing nullability/defaults.
- All FK targets and referenced unique keys, including composite tenant+parent keys.
- Exact RLS policies, function EXECUTE grants and service-role caller chain.
- Every dependent writer/reader and n8n payload mapping.
- Collision and historical lineage counts using aggregate-only queries.
- A migration rollback plan tested against a disposable clone or isolated test project.

## Safety boundary

This audit used catalog/function-definition reads only. No DDL, DML, migration apply, function replacement, Worker/Edge Function deploy, n8n workflow edit, Shopify release, PR merge or production change occurred.
