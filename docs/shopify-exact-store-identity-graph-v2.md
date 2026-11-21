# Exact-store customer, session and checkout identity V2

**Status:** preparation-only candidate; not applied to live Supabase.
**Depends on:** candidate migrations 001, 007 and 008.
**Safety boundary:** the V2 graph is isolated from legacy customers, sessions, aliases, checkouts, canonical events, recovery, delivery, attribution and billing.

## What this stage implements

Migration 009 creates separate exact-connection identity tables:

- `shopify_customer_identity_v2`: pseudonymous Shopify customer references, unique by exact Shopify connection. No email column or email-based identity fallback.
- `shopify_session_identity_v2`: session references unique by exact Shopify connection, with a composite same-store customer relationship.
- `shopify_session_alias_identity_v2`: aliases unique by exact connection and constrained to a session belonging to that same connection.
- `shopify_checkout_identity_v2`: checkout IDs/tokens scoped to exact connection, tied to a verified webhook receipt from that same connection, and with same-store customer/session constraints.

All four tables are RLS-enabled, revoked from PUBLIC/anon/authenticated/service_role for direct table access, and are writable only through narrowly scoped SECURITY DEFINER RPCs. The migration creates no historical backfills and leaves all legacy V1 functions and uniqueness constraints untouched.

## Pixel identity projection RPC

`henvalt.project_shopify_pixel_identity_v2(p_inbox_id)` consumes one row from the isolated V2 pixel inbox.

- The tenant and Shopify connection are read from the inbox row created by the key/origin-validated pixel ingestion RPC; callers cannot submit or override either identity.
- It requires the source Shopify connection and tenant to remain active.
- Analytics consent false, or absent client reference, marks the inbox row processed without creating customer/session/alias identity rows.
- Customer identity is created only when a Shopify customer reference is present, keyed by connection plus external customer reference.
- Session identity is keyed by connection plus client reference.
- Checkout alias is keyed by connection plus alias and cannot be rebound to a different session.
- An existing session linked to a different customer identity causes the transaction to fail closed.
- Exact retries of a processed inbox row return a duplicate result.

Marketing consent is stored separately in the inbox and never authorizes identity projection.

## Checkout writer boundary

The checkout identity table is prepared, but no checkout projection RPC is enabled yet. The current verified webhook inbox stores the authenticated body digest and routing metadata, not the original parsed checkout fields. A future adapter must parse the authenticated raw body and atomically bind parsed checkout fields to the exact verified receipt before this table can be written. Do not accept caller-supplied connection IDs or unverified checkout payloads.

## Explicit non-actions

- No V1 function is replaced or altered.
- No tenant-only unique constraint is dropped.
- No legacy customer/session/checkout row is backfilled.
- No V2 identity row is made visible to existing recovery or delivery consumers.
- No live migration, data change, Worker/Edge deployment, n8n edit, Shopify setting or release is performed.
