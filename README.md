# HENVALT Shopify integration

## Verified components
- Shopify OAuth Edge Function is deployed and uses authenticated install initiation, one-time hashed state, callback HMAC validation, owner-aware finalization, and Vault-backed Shopify token storage.
- OAuth callback source registers and verifies nine Shopify webhook topics against the HENVALT Cloudflare ingress Worker. Dynamic merchant OAuth installation and a real customer event still require end-to-end verification.
- Cloudflare ingress Worker source is included for review. The production Worker is managed separately; do not deploy changes without comparing the live Worker and preserving its secret bindings.
- `henvalt-merchant-dashboard` is deployed. It validates the Supabase user session, resolves the user's tenant and active Shopify connection server-side, and reads tenant-scoped metrics through the service-role-only dashboard summary RPC.
- `henvalt-mailersend-setup` validates the MailerSend token and verified sender domain, then stores the tenant credential in Supabase Vault. Setup does not send email.
- `henvalt-mailersend-delivery` is deployed. It accepts calls only from the Supabase service-role identity, retrieves the already-authorised tenant's MailerSend credential server-side, and never returns that credential to n8n.
- The delivery-token RPC is executable only by `service_role`. It requires a delivery request already claimed by `authorize_delivery_request`, atomically permits one provider attempt per request, and requires the tenant's MailerSend credential and sender domain to be verified.
- `HENVALT_DELIVERY` now uses the tenant-scoped delivery Edge Function in its published active version; the previous global n8n MailerSend credential is no longer used by the send node.
- `HENVALT_INGEST` now correctly maps the top-level Shopify customer ID from `customers_email_marketing_consent/update` into the normalized customer identity. The fix is published.
- A manual negative-path test confirmed that an unknown delivery request is rejected before the provider send node and is not recorded as a provider attempt. No email was sent during this test.
- Multi-step recovery is now supported: a provider-accepted checkout/cart message can schedule steps 2 and 3 at 24 and 48 hours from sequence start (payment-failure sequences are capped at 2). Supabase rechecks active store, unrecovered opportunity, email consent, suppression, and verified sender before creating each next intervention.
- Recovery context now includes the intervention step, prior message subject/body, and normalized line items from Shopify checkout/cart events. The model is instructed to avoid repeating earlier copy and to use only supplied product facts.
- The merchant dashboard UI is published on Cloudflare Pages at `https://henvalt-dashboard.pages.dev`; the current immutable deployment URL is `https://8ffdc377.henvalt-dashboard.pages.dev`.

## Required Supabase Edge Function secrets
The Shopify OAuth function requires:
- `SHOPIFY_API_KEY`
- `SHOPIFY_API_SECRET`
- `SHOPIFY_REDIRECT_URI` (must exactly match the Shopify Dev Dashboard callback URL)
- Optional `SHOPIFY_SCOPES` (the source always requests `read_orders,read_customers`)

Never commit access tokens, API secrets, service-role keys, or MailerSend keys.

## OAuth routes
- `GET /auth?shop={shop}.myshopify.com` (requires authenticated merchant bearer token)
- `GET /callback?shop=...&code=...&state=...&hmac=...`
- `GET /health`

## Launch gates still open
- Reauthorize a real test store with both `read_orders` and `read_customers`; the currently active test connection has only `read_orders`.
- Request the required protected customer data and email-field access in Shopify Partner Dashboard. A scope alone does not guarantee customer email fields are returned.
- Migrate the OAuth flow from per-user online tokens to expiring offline access tokens, store the refresh-token pair securely, and implement token rotation before relying on Shopify Admin API calls from background jobs.
- Complete a real merchant OAuth install and verify all nine webhook registrations in that shop.
- Deliver an identifiable, consent-eligible checkout/cart event through Cloudflare → n8n → Supabase. Synthetic payloads without customer identity, checkout value, and consent do not qualify.
- Verify a legitimate recovery opportunity can be claimed and processed by `HENVALT_RECOVERY`.
- Re-run tenant MailerSend setup for the test store and verify that the sender domain is stored as verified. The currently stored test configuration has no verified-domain metadata, so the new delivery gateway will fail closed.
- Only after explicit approval, perform a controlled end-to-end email test to an address the user controls. No production email is sent during provider setup.
- Verify a real recovered order and attribution before claiming recovered revenue or enabling performance billing.

The integration is not launch-ready until the launch gates above are verified. Synthetic webhook tests prove ingress and event persistence only; they do not prove recovery or revenue.

## Shopify OAuth token lifecycle

The OAuth callback requests **expiring offline Admin API tokens** (`expiring=1`); it does not request per-user online tokens. Shopify returns an access token plus a rotating refresh token and both lifetimes. The callback persists both credentials in Supabase Vault and records their expiry metadata in `henvalt.shopify_connections`. The refresh secret is never returned to the browser or n8n.

**Important launch gate:** token refresh/rotation must be wired into the server-side Shopify API execution path before any background Admin API calls rely on these credentials. Refreshes must persist each returned access/refresh pair atomically; a failed or expired refresh requires merchant reauthorization. Do not revert to non-expiring or online per-user tokens.

## Shopify refresh-token rotation service

`henvalt-shopify-token-refresh` is deployed as an internal service-role-only Edge Function. It serializes refresh attempts per shop with a database lease, reads the refresh credential only inside the privileged database claim, calls Shopify with `grant_type=refresh_token`, and persists the returned access/refresh pair together in Vault before clearing the lease. It records reauthorization-required state for invalid/expired refresh credentials and leaves transient network/provider failures retryable. Token values are never returned in the HTTP response or logged.

The refresh service is an infrastructure primitive, not a scheduled job: the current app/dashboard and n8n workflows do not make Admin API calls using stored shop tokens. Any future server-side Admin API caller must check expiry and invoke this service before using an expiring offline token. Do not add per-user online tokens or bypass rotation.
