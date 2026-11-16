# Live Shopify Edge Function app-identity audit

**Status:** read-only inspection of deployed Supabase Edge Function source; no deployment  
**Date:** 2026-11-16  
**Project:** ocyplckdojdubyrsxcxa

## Inspected deployed functions

| Function | Version | JWT gateway |
|---|---:|---|
| henvalt-shopify-oauth | 27 | disabled; handler performs its own callback/state validation |
| henvalt-shopify-token-refresh | 1 | enabled; handler additionally requires service-role bearer |
| henvalt-control-plane | 24 | disabled; handler validates HENVALT API bearer |
| henvalt-pixel-ingest-proxy | 3 | disabled; server-side pixel key validation is delegated to narrow RPC |

Source fingerprints were recorded from the deployed function metadata during inspection. No environment variable values or secrets were read.

## Confirmed findings

### 1. OAuth Edge Function is single-app

The deployed OAuth function reads one set of environment variables:
- SHOPIFY_API_KEY
- SHOPIFY_API_SECRET
- SHOPIFY_REDIRECT_URI

The same API secret verifies callback HMAC and the same client ID/secret exchange the authorization code. OAuth state creation persists only state hash, shop domain, expiry and initiating user. Callback reads state by hash and checks shop, owner, expiry and consumed status. It calls the legacy `control_plane_finalize_shopify_oauth_install_expiring_for_owner` RPC, which is also app-unaware.

The function receives a connection ID from the finalizer result and correctly uses it for pixel key provisioning/reuse. That local pixel activation step is already connection-aware, but the OAuth identity/credential selection before it is not.

**Required public-v2 design:** separate callback route or trusted route-to-app mapping; resolve app config server-side; persist app_key and callback route in state; verify callback HMAC with that app's secret; exchange code with that app's client credentials; call a v2 finalizer with exact app key/state/connection; reject cross-app shop conflicts before token Vault writes. No client-provided app key or secret reference is trusted.

### 2. Token refresh Edge Function is single-app and shop-domain keyed

The deployed token-refresh function reads one SHOPIFY_API_KEY and SHOPIFY_API_SECRET. It accepts shop_domain, calls legacy claim/complete/fail refresh RPCs with shop domain, exchanges refresh token using the one configured client identity, and completes by shop domain.

It has no app_key or connection ID input. Its gateway JWT is enabled and it additionally compares bearer token to service-role key.

**Required public-v2 design:** use trusted connection ID/app key derived from server-side job claim, resolve registry credentials internally, and claim/complete/fail refresh against exact connection ID. Never accept an arbitrary app key from a public request. Preserve legacy refresh path for existing connections until v2 is fully tested.

### 3. Control Plane Edge Function is shop-domain keyed

The deployed control-plane function resolves the connection via `control_plane_shop_connection(p_shop_domain)` and passes shop domain to the majority of control-plane RPCs, including billing, sender profile, token retrieval and disconnect. It authenticates a HENVALT bearer before accepting the shop header, but the shop header itself is not an app identity.

For the first rollout, a verified authenticated user + authorized tenant membership + globally unique shop domain may continue to locate one connection for merchant UI; however, all data readers/mutators must internally resolve the exact connection and avoid tenant-wide aggregation. Any public app-specific credential or callback route must not rely on this legacy API contract.

### 4. Pixel ingestion proxy delegates identity to the pixel key

The deployed pixel proxy forwards the key digest, origin, collector secret and payload to `henvalt_ingest_pixel_event`. It does not accept app_key or connection ID. The database must resolve the digest to the active pixel key and inherit the exact `pixel_keys.shopify_connection_id`. This is an acceptable trusted identity pattern only if the RPC enforces active key, exact origin and connection binding and writes that connection to canonical event lineage; the RPC must be inspected and upgraded before multi-store event writers use public-v2.

## End-to-end blocker list

The next public-app implementation cannot safely stop at OAuth:
1. OAuth callback, app registry, state, HMAC and finalizer must be app-aware.
2. Token refresh must use exact connection identity and app credentials.
3. Webhook Worker + HENVALT_INGEST + HMAC verifier must share the trusted app/connection envelope.
4. Pixel ingest must preserve its existing pixel-key connection identity into canonical events.
5. Control-plane dashboard, billing, sender and disconnect RPCs must be connection-safe and correctly scoped.
6. Recovery candidate, consent, delivery authorization, reply, unsubscribe, privacy and attribution must enforce the same connection lineage.

## Safety boundary

Inspection only. No Edge Function was edited or deployed, no secret value was read, and no production RPC was changed. This audit does not authorize a new Shopify app registration, migration, credential write, Worker edit, n8n edit or deployment.
