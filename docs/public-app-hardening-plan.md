# HENVALT Public-App Hardening Plan

Status: preparation only. This document describes the work required before a separate Partner-owned public app can safely share HENVALT's existing backend. It does not authorize deployment, release, Shopify app creation, billing, or production database changes.

## Existing app protection

- Keep the current merchant-owned Shopify app and its client ID/secret operational as the legacy app.
- Do not overwrite the current global Shopify credentials with credentials for a future public app.
- Do not change existing shop connections or access tokens during preparation.
- The current `shopify_connections` model is shop-domain keyed. Until the schema and every shop-specific operation are made app-aware, enforce one active HENVALT app identity per shop and reject a conflicting install rather than silently replacing a connection.

## App identity model

Introduce a stable internal app key (for example, `legacy` and `public_v1`) distinct from the Shopify client ID.

- Store app key, Shopify client ID, active state, and a Vault secret reference in a private app registry.
- Keep the Shopify app secret in Supabase Vault / secret bindings only. Never put plaintext secrets in ordinary database rows, Git, workflow logs, or client code.
- Persist the app key in OAuth state and on each Shopify connection.
- OAuth callback HMAC verification and token exchange must select credentials from the app key associated with the one-time OAuth state, not from a global secret.
- Token refresh must resolve the same app identity and corresponding Vault secret as the original connection.
- Enforce the shop/app uniqueness rule transactionally. A conflicting install must fail closed with a clear migration path.

## Webhook ingress and verification

- Preserve the existing legacy endpoint and its current secret binding.
- Add a distinct, explicit route for each registered app key, such as `/shopify/webhooks/public_v1`.
- The Cloudflare Worker must select the secret from a server-controlled app-key allow-list, read the raw body once, and verify Shopify HMAC before forwarding.
- Never choose an app identity from an unsigned shop-domain header.
- After successful verification, forward the app key as an internal routing header to HENVALT_INGEST.
- The n8n verification step must call an app-aware Supabase verifier using the app key and original raw-body bytes. The current single-secret RPC is not sufficient for a second app.
- Tenant resolution must bind both app key and shop domain. Unknown app keys, inactive apps, and conflicting connections must fail closed.

## Shopify privacy compliance

The current branch now declares all three mandatory topics in `shopify.app.toml` for the existing merchant-owned app, using its current privacy Edge Function endpoint. This declaration is preparation only and has not been deployed. That endpoint verifies the existing app's single global secret; it must **not** be reused by a future Partner-owned app until app-specific secret routing is implemented.

The future public app configuration must also declare all three mandatory topics:

- `customers/data_request`
- `customers/redact`
- `shop/redact`

The compliance endpoint must use the same app-specific HMAC selection as normal webhooks, persist requests idempotently, and preserve the current review/processing behavior. Do not point a second app at the existing single-secret privacy function until it can identify and verify the correct app secret.

Shopify's app configuration documentation requires these three topics for App Store distribution. Configuration changes are not live until a Shopify app deployment is performed; no deployment is part of this preparation work.

## Pixel event contract

The pixel extension already subscribes to `product_removed_from_cart`. The Supabase ingestion function already accepts it, but the Cloudflare pixel collector did not. The preparation branch now adds that event to the collector allow-list and strengthens static validation so every pixel subscription must also be accepted by the collector.

## Required regression coverage before any release

1. Legacy app OAuth callback still verifies with the legacy secret.
2. Public app OAuth callback verifies only with the public app secret.
3. Wrong app key, wrong secret, tampered body, missing HMAC, and unknown shop are rejected.
4. A public-app install cannot overwrite a legacy connection for the same shop.
5. Token refresh selects the original app's credentials.
6. All three privacy topics verify with the correct app secret and persist once under duplicate delivery.
7. Webhook events are routed to the correct tenant and app identity.
8. Pixel events across page view, product view, add-to-cart, remove-from-cart, and checkout-started are accepted end-to-end.
9. Consent revocation and opt-out suppression remain enforced before any delivery.
10. Existing checkout/cart/browse recovery and attribution regressions remain green.

## Release boundary

This branch is preparation only. Do not merge, deploy Cloudflare, deploy Supabase functions or migrations, change n8n workflows, create a new Shopify app, or release a Shopify version without separate explicit authorization and verified regression results.

## Code audit: confirmed implementation gaps (2026-11-15)

Read-only inspection of the current preparation branch confirms these are code-level blockers, not merely future recommendations:

| Component | Current implementation | Required before a second app |
|---|---|---|
| `supabase/functions/henvalt-shopify-oauth/index.ts` | Reads one `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET`; OAuth state stores shop, expiry, and initiating user only. Callback HMAC and token exchange use those globals. | Resolve a registered app key before creating state; persist it in state; callback must load that same app key and verify/exchange with its credentials. |
| OAuth finalization RPC | Called with state hash and shop, but no app key. | Add app-aware finalization and transactional conflict protection before changing the function call. |
| `supabase/functions/henvalt-shopify-token-refresh/index.ts` | Uses one global key/secret; claim, fail, and complete RPCs are shop-domain-only. | Claim must return immutable app identity with the refresh token; use that app's credentials for refresh and pass app identity through all completion/failure RPCs. |
| `cloudflare/worker.js` | Accepts only `/shopify/webhooks` and verifies every webhook with `env.SHOPIFY_API_SECRET`; forwards the original headers/body to one n8n URL. | Add explicit app-key routes and a server-controlled app-secret registry; verify raw bytes before forwarding; forward a trusted app key only after verification. |
| OAuth webhook registration | Registers every topic at the same `/shopify/webhooks` URL. | Register legacy and public app subscriptions to distinct explicit routes; do not point both at a single-secret verifier. |
| n8n ingress verifier | Existing integration calls a single-secret HMAC verifier. | Add app-aware verification using the verified app key and original raw-body bytes before tenant resolution. |
| Database identity | OAuth state, connection, refresh RPC, and tenant resolution are currently shop-domain-oriented. | Add app identity with transactional constraints and update every shop-keyed security boundary together; fail closed until complete. |

### Safe implementation order

1. Inventory and design the database contract first: app registry, Vault secret references, OAuth state app key, connection app key, one-active-app-per-shop constraint, and app-aware RPC signatures.
2. Implement and test the database contract in an isolated database branch or migration review; do not apply it to production as part of this PR.
3. Implement a shared app resolver and update OAuth install/callback and refresh together.
4. Update webhook Worker routing and n8n verification together. Never forward a second app's event to the legacy single-secret RPC.
5. Update privacy verification and the future app's TOML route only after the app-aware verifier is deployed and independently tested.
6. Run legacy regression tests plus dual-app, wrong-key, replay, tampered-body, conflict-install, token-refresh, privacy, tenant-routing, and uninstall tests.
7. Only then request separate authorization for production rollout and Shopify app distribution.

**Important:** This repository does not contain the live Supabase schema definitions or n8n workflow source needed to safely implement steps 1–4 end-to-end in this branch. The present code audit therefore deliberately stops short of introducing a partial second-app implementation that could falsely appear production-ready.

## Database audit: live read-only findings (2026-11-15)

The live Supabase project was inspected using read-only catalog queries and table metadata. No SQL writes, migrations, secret reads, or production changes were made.

### Confirmed schema contract

- `henvalt.shopify_oauth_states` has `state_hash`, `shop_domain`, `created_at`, `expires_at`, `consumed_at`, `correlation_id`, and `initiated_by_user_id`. It has no `app_key` or Shopify client/app identifier.
- `henvalt.shopify_connections` has tenant/shop/token-secret-reference/refresh-lease fields, but no `app_key` or Shopify app identifier.
- `shopify_connections_shop_domain_key` enforces `UNIQUE (shop_domain)`; a second app cannot create a second connection row for the same shop. A second uniqueness rule also exists on `(tenant_id, shopify_shop_id)`.
- Token secret references are stored as Vault references, not plaintext tokens. Preserve this pattern when introducing app secrets.

### Confirmed database function contracts

| Function | Live signature | App-identity gap |
|---|---|---|
| `henvalt.resolve_shopify_tenant` | `(p_shop_domain text) returns uuid` | Resolves only by shop domain; no app key participates in tenant selection. |
| `henvalt.verify_shopify_webhook_hmac` | `(p_hmac text, p_raw_body_base64 text) returns boolean` | Loads the one Vault secret named `henvalt_shopify_app_secret`; no app key parameter. |
| `henvalt.claim_shopify_token_refresh` | `(p_shop_domain text, p_force boolean) returns jsonb` | Claims by shop domain and returns a refresh token without an app identity. |
| `henvalt.complete_shopify_token_refresh` | `(p_shop_domain text, p_access_token text, p_refresh_token text, p_access_expires_in integer, p_refresh_expires_in integer)` | Persists the token pair by shop domain only. |
| `henvalt.fail_shopify_token_refresh` | Existing Edge Function calls it with shop domain and error fields only. | Failure/lease handling is not bound to an app identity. |

### Design consequence

The database change cannot safely be limited to adding an `app_key` column. The OAuth state-consumption path, connection insert/upsert, tenant resolution, webhook HMAC verification, and all three token-refresh RPCs must agree on the same app identity. Shop-specific control-plane and recovery functions that currently look up a connection by `shop_domain` must also be reviewed. The first safe rollout policy should remain **one active HENVALT app identity per shop**, unless and until every dependent operation is explicitly made multi-app aware.

The database audit confirms the existing legacy app can remain intact while a future app identity is added in a coordinated migration. It does not establish that dual-app installation or same-shop coexistence works today.
