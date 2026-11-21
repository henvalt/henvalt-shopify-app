# App-aware OAuth finalizer — branch-only implementation contract

Status: candidate SQL migration and static tests only. Not applied to Supabase.

## Transaction behavior

Migration 004 adds a service-role-only SECURITY DEFINER wrapper around the existing expiring-token OAuth finalizer. It verifies, in one database transaction:

- OAuth state belongs to the same shop, initiating user, and server-resolved app key.
- The supplied Shopify client ID maps to exactly one active registry row for that app key.
- The shop-domain advisory lock serializes installation against the existing connection resolver.
- An existing connection is never rebound from one non-null app key to another.
- The established finalizer performs its existing token Vault writes, membership, audit and state-consumption behavior.
- The returned connection is bound to the app key, and only the SHA-256 hash of the 256-bit route token is inserted.
- Any failure raises and rolls back token writes, state consumption, connection changes and route-token insertion together.

The Edge Function must generate the route token using `crypto.getRandomValues(new Uint8Array(32))`, encode it as 64 lowercase hex characters, and retain it only in request memory. It must never log it. The callback registration path is constructed from that in-memory value only after this RPC succeeds.

## Critical integration requirements still outstanding

1. OAuth start must resolve the app key from configured `SHOPIFY_API_KEY` by exact lookup against active registry rows. Browser input must not select the app.
2. The OAuth state insert must persist the resolved `app_key`.
3. Callback HMAC and token exchange must use credentials for that exact registry app, not the legacy global secret.
4. The callback must call migration 004 with the same state app key and configured client ID.
5. V2 callback registration must remain behind a server-side flag defaulting to false; legacy callback registration remains unchanged while disabled.
6. Reauthorization must rotate/revoke the previous route token and reconcile existing webhook subscriptions before enabling V2. Migration 004 currently inserts a fresh token and intentionally does not implement rotation or webhook registration.
7. Validate migration 004 in a disposable PostgreSQL/Supabase environment against the exact predecessor migrations and the live finalizer signature before any application.

## Known limitations

- This migration depends on migrations 001 and 003 and is not production-ready until disposable database testing succeeds.
- It does not seed the legacy merchant-owned app or a future public app.
- No new public app credentials exist in this implementation.
- No OAuth Edge Function source is modified by this change.
- No migrations are applied, no tokens are issued, and no Shopify webhook subscriptions are changed.
