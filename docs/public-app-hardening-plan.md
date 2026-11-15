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
