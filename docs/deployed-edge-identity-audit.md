# Deployed Shopify Edge Function identity audit

**Status:** read-only inspection of deployed function source and live table columns. No function was changed or deployed.

## Privacy webhook handler: `henvalt-shopify-privacy` (deployed v1)

Verified behavior:
- Reads one environment secret, `SHOPIFY_API_SECRET`, for HMAC verification. There is no app-key or app-specific secret selection.
- Reads `X-Shopify-Shop-Domain`, verifies the raw-body HMAC, then looks up `shopify_connections` by `shop_domain` with `limit=1`, selecting only `tenant_id,shopify_shop_id`.
- Does not select or persist `shopify_connections.id` as the request's authoritative connection.
- Inserts `shopify_privacy_requests` with `tenant_id`, `shop_domain`, `shopify_shop_id`, topic, webhook ID, customer ID, request ID, payload and status.
- Calls `export_shopify_customer_data` and `redact_shopify_customer_data` using tenant ID + customer ID/email only.
- Calls `redact_shopify_shop_data` for `shop/redact`; the inspected DB function deletes the resolved tenant.
- Correctly retains unmatched shop requests as `REVIEW_REQUIRED` rather than silently discarding them. Preserve this property.

Live table shape for `shopify_privacy_requests` contains no `shopify_connection_id` or `app_key`. The table has a unique webhook ID conflict target, and keeps the shop domain and Shopify shop ID. This is insufficient to distinguish multiple app identities or to scope customer privacy processing to a specific connection.

**Required:** route to app-specific HMAC secret using trusted app identity; persist app key and exact connection ID (nullable for unresolved requests); use historical connection resolution where needed; pass connection ID to customer export/redaction; define safe shop-redaction semantics when a tenant has multiple stores.

## OAuth installer: `henvalt-shopify-oauth` (deployed v27)

Verified behavior:
- Reads a single `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET` pair from environment.
- OAuth state creation persists state hash, shop domain, expiry and initiating user ID. No app key or client identity is written to state.
- Callback validates HMAC using the one configured secret, looks up the state by hash/shop, then exchanges the code using the same global client ID/secret.
- The finalization RPC receives state hash, shop domain, tokens, Shopify shop ID, scopes and user ID; no app identity is supplied.
- Pixel activation and Shopify webhook registration happen after finalization.

**Required:** add an explicit app-key allow-list and bind app key to OAuth state before authorization begins. Callback must resolve exactly the same registered app identity from state, verify callback HMAC with that app's secret, and finalize the connection with that identity. Do not infer app identity from an unsigned shop header or browser-supplied app key.

## Token refresh: `henvalt-shopify-token-refresh` (deployed v1)

Verified behavior:
- Reads the same single global Shopify API key/secret pair.
- Claims token refresh by shop domain using `claim_shopify_token_refresh(p_shop_domain,p_force)`.
- Refreshes the token with the global app client credentials, then completes/fails refresh by shop domain.
- No app identity is present in request, claim, or completion calls.

**Required:** refresh must resolve app identity from the stored connection and use that app's registered credentials. Shop-domain-only refresh RPCs must not choose credentials from caller input.

## Consequence for the proposed rollout

The existing legacy app path and any future Partner-owned public app cannot safely share the currently deployed OAuth, refresh, and privacy functions as-is. Multi-app support must be implemented as a coherent identity boundary across:
1. App registry and secret references.
2. OAuth state, callback validation, and connection persistence.
3. Token refresh claim/complete/fail.
4. Shopify webhook HMAC verification and privacy request receipt.
5. Cloudflare ingress and n8n/Supabase verification.
6. Tenant + connection authorization and store-scoped records.

Until then, the existing global-secret functions remain legacy-only. This audit does not change that live behavior.
