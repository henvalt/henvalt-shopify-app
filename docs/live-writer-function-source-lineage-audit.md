# Live writer-function and source-lineage audit

**Status:** read-only production inspection; findings only; no deployed changes  
**Date:** 2026-11-16  
**Project:** ocyplckdojdubyrsxcxa  
**Schema:** henvalt

## Scope

Inspected live PostgreSQL function catalog and selected function bodies for:
- `control_plane_connect_shop`
- `control_plane_finalize_shopify_oauth_install_expiring_for_owner`
- `upsert_customer`
- `upsert_checkout`
- `upsert_canonical_event`
- `resolve_identity`
- `project_order_from_event`

Also checked non-internal triggers on the anchor and projection tables:
`shopify_connections`, `shopify_oauth_states`, `webhook_events`, `canonical_events`, `customers`, `checkouts`, `orders`.

No non-internal triggers were returned for those selected tables. This does not rule out triggers elsewhere in the dependency graph or application-side transformations.

## Confirmed findings

### 1. OAuth finalization can reactivate and rewrite a shop-domain connection

The live owner finalizer:
1. Locks and validates one OAuth state by state hash, shop domain, initiating user, expiry and consumed status.
2. Calls `control_plane_connect_shop(p_shop_domain)`.
3. The connect function resolves an existing connection by normalized shop domain, or creates a tenant and connection if none exists.
4. Existing connection is set active; then the finalizer writes access/refresh token Vault references and expiry metadata onto that connection.
5. The finalizer consumes the state and creates/ensures tenant owner membership.

Neither function accepts app_key or an explicit connection ID. This confirms the old finalizer is not safe as a public-app callback contract. The public v2 finalizer must resolve a trusted app-aware OAuth state, check same-shop app conflict **before** any Vault write or connection reactivation, then write tokens to the exact locked connection ID. Keep the legacy finalizer legacy-only.

### 2. Customer identity is tenant-scoped

Live `upsert_customer` accepts tenant ID, Shopify customer ID, email and profile/consent metadata; it has no connection ID argument or lookup. It matches a customer by tenant + Shopify customer ID, or by tenant + email when external customer ID is absent.

Impact: two stores in one tenant can collapse the same Shopify customer ID or email into one customer row. Appending shop domain into arbitrary metadata does not make this a referentially safe identity boundary.

Required successor: `upsert_customer_v2(p_tenant_id, p_shopify_connection_id, ...)`, with a composite tenant+connection FK and uniqueness scoped to the connection. Email fallback must be connection-scoped by default; any tenant-wide identity linking must be an explicit, separately consented policy.

### 3. Checkout identity is tenant-scoped

Live `upsert_checkout` accepts tenant ID, Shopify checkout ID, customer ID, checkout token, session reference, email, value/status and metadata. It has no connection ID argument. The function is large (65,647 characters in the live catalog snapshot) and uses conflict handling. The checkout table's known unique constraints are tenant-scoped.

Required successor: exact connection argument and validation of the customer/session lineage; checkout external ID and checkout token uniqueness scoped to connection. Preserve current RPC for legacy callers until all callers can dual-write and v2 tests pass.

### 4. Canonical event writer is tenant-scoped

Live `upsert_canonical_event` accepts tenant ID, optional webhook event ID, source/event identifiers, customer/email/session references, payload/metadata and idempotency key. It has no connection ID argument and no typed connection check.

Required successor: canonical event must inherit connection ID from the referenced webhook receipt. Pixel-derived canonical events must inherit from the exact `pixel_keys.shopify_connection_id`. If a caller provides a connection ID, treat it as a consistency assertion only; never trust it as the identity source.

### 5. Identity resolver is tenant-only

Live `resolve_identity(p_event_id)` reads tenant and identity references from canonical event, then resolves customers, session aliases, sessions and checkouts by tenant-scoped values. It has no connection ID predicate.

Required successor: read trusted connection ID from the canonical event and scope customer, session, alias and checkout lookup/create to that connection. A missing connection ID must not fall back to tenant-wide matching for public traffic.

### 6. Order projection is tenant-only

Live `project_order_from_event(p_event_id)` reads tenant + payload from canonical event; finds existing order by tenant + Shopify order ID; resolves customer by tenant + email or Shopify customer ID; and resolves checkout by tenant + Shopify checkout ID. It inserts/updates orders with tenant-only relationships and source event metadata, without a typed connection ID.

Required successor: derive connection from canonical event; resolve order/customer/checkout only inside that connection; enforce same-connection source event, customer and checkout; persist connection on order and composite FKs before enabling multi-store recovery/attribution.

### 7. Trigger result

No non-internal triggers were returned on the selected anchor/projection tables. This reduces the chance of hidden trigger-based connection propagation on those exact tables, but it is not proof that no other trigger or Edge Function writer exists elsewhere.

## Implementation implications

The safe first database slice is not only a registry plus two anchor columns. It needs:
1. nullable app_key on connections and OAuth state;
2. trusted app-aware resolver/finalizer v2;
3. nullable connection ID on webhook and canonical event;
4. connection-aware writer successors for canonical event, customer, checkout and order projection;
5. composite tenant+connection constraints and uniqueness;
6. dual-write/read-compare period before any public traffic or recovery send uses the new lineage.

Do not enable v2 public traffic until all relevant ingress writers and the event-to-order projection path use exact connection identity. Candidate discovery, consent, recovery, delivery and attribution remain additional blockers even after these writers are fixed.

## Required regression cases

- Same Shopify customer ID in two stores under one tenant produces two connection-bound customers.
- Same email in two stores does not silently merge records across connections.
- Same checkout ID/token in two stores does not conflict or cross-link.
- Canonical event connection must equal its webhook receipt connection.
- Pixel event connection must equal its pixel key connection.
- Event with missing/ambiguous connection cannot enter public app processing.
- Order projection uses only customer and checkout rows from its source event connection.
- A legacy OAuth finalizer cannot be called by public callback route.
- Same-shop public-vs-legacy install conflict fails before connection activation or Vault token writes.

## Boundaries

This audit did not read or output secret values, tokens, customer records, or raw merchant identifiers. It did not change production SQL, Edge Functions, Worker routes, n8n workflows, Shopify app settings or GitHub default branch. It is not approval to apply a migration.
