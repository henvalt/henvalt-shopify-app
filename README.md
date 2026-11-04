# HENVALT Shopify integration

## Verified components
- Shopify OAuth Edge Function is deployed and uses authenticated install initiation, one-time hashed state, callback HMAC validation, owner-aware finalization, and Vault-backed Shopify token storage.
- OAuth callback source registers and verifies nine Shopify webhook topics against the HENVALT Cloudflare ingress Worker. Dynamic merchant OAuth installation and a real customer event still require end-to-end verification.
- Cloudflare ingress Worker source is included for review. The production Worker is managed separately; do not deploy changes without comparing the live Worker and preserving its secret bindings.
- `henvalt-merchant-dashboard` is deployed. It validates the Supabase user session, resolves the user's tenant and active Shopify connection server-side, and reads tenant-scoped metrics through the service-role-only dashboard summary RPC.
- `henvalt-mailersend-setup` validates the MailerSend token and verified sender domain, then stores the tenant credential in Supabase Vault. Setup does not send email.
- `henvalt-mailersend-delivery` is deployed. It accepts calls only from the Supabase service-role identity, retrieves the already-authorised tenant's MailerSend credential server-side, and never returns that credential to n8n.
- The delivery-token RPC is executable only by `service_role`. It requires a delivery request already claimed by `authorize_delivery_request` and atomically allows one provider attempt per request.
- The `HENVALT_DELIVERY` draft now routes its MailerSend send step through the tenant-scoped delivery Edge Function. This draft is not yet published; the active workflow version remains unchanged until a controlled, consent-valid test is approved.
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
- Complete a real merchant OAuth install and verify all nine webhook registrations in that shop.
- Deliver an identifiable, consent-eligible checkout/cart event through Cloudflare → n8n → Supabase. Synthetic payloads without customer identity, checkout value, and consent do not qualify.
- Verify a legitimate recovery opportunity can be claimed and processed by `HENVALT_RECOVERY`.
- Verify the tenant-scoped MailerSend delivery draft using the merchant's own credential, then publish only after a controlled test.
- Only after explicit approval, perform a controlled end-to-end email test to an address the user controls. No production email is sent during provider setup.
- Verify a real recovered order and attribution before claiming recovered revenue or enabling performance billing.

The integration is not launch-ready until the launch gates above are verified. Synthetic webhook tests prove ingress and event persistence only; they do not prove recovery or revenue.
