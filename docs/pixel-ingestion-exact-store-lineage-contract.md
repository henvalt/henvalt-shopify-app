# Shopify Pixel Ingestion — Exact Store-Lineage Contract

**Status:** implementation design / review-only. No production function or schema was changed.
**Source inspection date:** 2026-11-16
**Scope:** preserve the trusted `pixel_keys.shopify_connection_id` through event ingestion and all identity resolution.

## 1. Confirmed deployed behavior

Read-only inspection of the current branch's `cloudflare/pixel-collector.js` and deployed Supabase functions established this chain:

1. The browser sends a public pixel key and event payload to the Cloudflare collector.
2. The Worker hashes the public key and sends `p_key_digest`, origin, collector shared secret and sanitized event payload to the Supabase proxy.
3. Deployed `henvalt.ingest_pixel_event(p_key_digest, p_origin, p_payload)` validates the request and resolves the digest through `pixel_keys`.
4. Its connection join is already correct at this point: `pixel_keys.shopify_connection_id = shopify_connections.id`, with matching tenant, active connection, active/unrevoked key, allowed origin and active tenant.
5. **Identity is then dropped:** the function selects only `pk.tenant_id` into `v_tenant_id`. It does not retain `pk.shopify_connection_id`.
6. It calls `upsert_canonical_event` with `p_webhook_event_id = NULL`. That writer has no connection parameter and inserts only tenant-level identity.
7. It calls `resolve_identity(event_id)`, which selects customers by tenant + Shopify customer ID, then falls back to tenant + email; resolves sessions by tenant + session reference; and looks up checkouts by tenant + email/session.
8. `bind_session_alias(tenant_id, alias_reference, session_reference)` is also tenant-scoped and can bind aliases across stores in the same tenant.

The connection is therefore verified at the pixel-key boundary but discarded before durable event storage. Downstream identity resolution then uses tenant-wide customer/session/checkout matching.

## 2. Why a simple column addition is insufficient

Adding `canonical_events.shopify_connection_id` alone would not fix the pixel path:

- The current canonical writer cannot accept or persist the connection.
- The current identity resolver can attach the event to another store's customer by matching tenant + Shopify customer ID or email.
- Sessions and aliases are tenant-scoped and can merge references across stores.
- Checkout lookup is tenant/email/session scoped.
- The pixel idempotency key is currently `shopify-pixel:<event_id>`, and canonical event idempotency is tenant + idempotency key. Two stores under one tenant can therefore collide on an identical browser event ID.
- Existing historical pixel rows do not retain the pixel key digest or a typed connection ID. Current active key state cannot prove which key accepted an old event.

The safe unit of work is an app/store-aware pixel ingestion transaction plus store-scoped identity resolution—not a standalone canonical-event column.

## 3. Required V2 ingestion boundary

Implement a new versioned function (do not silently change the live function signature during preparation), for example:

`henvalt.ingest_pixel_event_v2(p_key_digest, p_origin, p_payload)`

The function must:

1. Validate digest format, origin, payload type/size, schema version, event allow-list, ID lengths and timestamp bounds as today.
2. Resolve the digest to exactly one active, unrevoked `pixel_keys` row.
3. Join to `shopify_connections` and verify connection active, tenant equality, and active tenant.
4. Capture `pixel_keys.id`, `pixel_keys.tenant_id`, and `pixel_keys.shopify_connection_id` into local variables.
5. Never accept tenant ID or connection ID from the browser payload or a caller-supplied header.
6. Insert the canonical event with the exact resolved connection ID in the same database transaction.
7. Use a connection-qualified idempotency key, e.g. `shopify-pixel:<connection_uuid>:<event_id>`, so identical browser event IDs in two stores do not collapse under the existing tenant+idempotency unique constraint.
8. Call a store-aware identity resolver with the same connection ID.
9. Bind checkout/session aliases only inside that connection.
10. Return only accepted/duplicate status and an opaque event identifier; do not expose internal connection IDs to the storefront.

Any missing, inactive, revoked, ambiguous or tenant-conflicting pixel-key/connection relationship must reject the event before writing.

## 4. Required store-aware writer and resolver contracts

### Canonical event writer

Create `upsert_canonical_event_v2` with an explicit `p_shopify_connection_id`.

- Require non-null connection ID for Shopify pixel and Shopify-origin events.
- Verify connection exists, is active where required, and belongs to `p_tenant_id`.
- If `p_webhook_event_id` is non-null, require the webhook receipt to have the same tenant and connection.
- If a caller supplies a connection that disagrees with the source parent, reject.
- Preserve existing canonical event ID and correlation behavior.
- Keep the old writer for legacy compatibility until all callers are migrated.
- Use a connection-qualified idempotency key at the caller boundary; do not drop or rewrite existing tenant-scoped unique constraints until every writer is inventoried.

### Customer identity

Add a connection reference to store-scoped Shopify customer mappings. Customer ID and email matching must include exact connection ID. Email fallback may find a customer only within the same store. A customer in Store B must never be attached to a Store A pixel event because the email is shared.

### Session and aliases

Add connection identity to sessions and session aliases. All lookup, creation, alias binding and conflict checks must use (tenant, connection, reference). A cart token or browser session string reused in another store must not merge the sessions.

### Checkout resolution

Checkout matching must include connection ID before comparing customer, email, cart token or session reference. A checkout from Store B must not be returned for a Store A event.

### Versioning and rollout

- Add new columns as nullable in an additive migration design.
- Add new V2 writer/resolver functions; do not change old function semantics in-place.
- Dual-write only from a verified source boundary.
- Keep historical rows with unknown connection NULL/quarantined.
- Shadow-compare V1 and V2 results; do not send or bill from V2 until tests and comparisons pass.
- Route only newly verified pixel events to V2 after separate release approval.
- Retain rollback to the old path for legacy behavior, but do not allow ambiguous old-path events to enter a multi-store public tenant's recovery queue.

## 5. Historical pixel data disposition

The live aggregate preflight found:
- 35 canonical events without webhook parents; all 35 have source `SHOPIFY_WEB_PIXEL`.
- 19 PAGE_VIEWED, 6 PRODUCT_ADDED_TO_CART, and 10 PRODUCT_VIEWED events.
- 16 pixel-key records exist, but only one is currently active and unrevoked.
- Existing canonical events do not store the pixel key digest or a typed connection ID.

**Decision:** all 35 historical pixel events remain unresolved for store identity. Do not backfill them from the current active pixel key, tenant membership, event timestamp, customer email, session, origin, or product data. If immutable request logs or another independent retained source later proves the exact key/connection for a specific event, that event may be reviewed individually; otherwise leave it unassigned and ineligible for store-specific recovery/attribution.

## 6. Required tests

1. Valid pixel key A creates a canonical event with connection A.
2. Valid pixel key B under the same tenant creates a canonical event with connection B.
3. Identical event IDs from A and B do not collide or return one another's event.
4. Duplicate event ID within A remains idempotent.
5. Invalid/revoked/inactive key rejects before canonical write.
6. Key A with origin not in A's allowed origins rejects.
7. Caller-supplied tenant/connection fields are ignored or rejected; only the stored key relationship determines identity.
8. Customer IDs reused across A/B resolve to distinct store-scoped customer rows.
9. Shared email across A/B never causes cross-store customer attachment.
10. Session references and checkout aliases reused across A/B remain distinct.
11. Checkout lookup for A never returns B's checkout.
12. Connection/tenant mismatch in canonical writer rejects.
13. A webhook-parent canonical event inherits the parent's exact connection and rejects a mismatch.
14. Historical pixel rows remain NULL/unresolved unless independent provenance is proven.
15. Pixel consent context is preserved; analytics-disabled events do not acquire customer identity through a fallback path.
16. Store B events cannot create, advance, suppress, or attribute Store A recovery.

## 7. Explicit non-actions

This document is not an executable migration. No DDL, DML, backfill, or function replacement was applied. No pixel key, connection, tenant, event, customer, session, checkout, or recovery row was changed. No Edge Function or Worker was deployed. Implementation and cutover require separate explicit authorization.
