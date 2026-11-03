# HENVALT Shopify integration

## Verified components
- Shopify OAuth Edge Function is deployed in Supabase and uses authenticated install initiation, one-time hashed state, callback HMAC validation, owner-aware finalization, and Vault-backed Shopify token storage.
- OAuth callback source registers and verifies eight Shopify webhook topics against the HENVALT Cloudflare ingress Worker. Dynamic merchant OAuth installation and a real customer event still require end-to-end verification.
- Cloudflare ingress Worker source is included for review. The production Worker is managed separately; do not deploy changes without comparing the live Worker and preserving its secret bindings.
- `henvalt-merchant-dashboard` is deployed. It validates the Supabase user session, resolves the user's tenant and active Shopify connection server-side, and reads tenant-scoped metrics through the service-role-only dashboard summary RPC.
- `henvalt-mailersend-setup` is deployed. It requires an OWNER/ADMIN membership, validates the MailerSend token and verified sender domain, and stores credentials through a service-role-only Vault configuration RPC. Setup does not send email.
- The merchant dashboard UI is published on Cloudflare Pages at `https://henvalt-dashboard.pages.dev`; the current immutable deployment URL is `https://8ffdc377.henvalt-dashboard.pages.dev`.

## Required Supabase Edge Function secrets
The Shopify OAuth function requires:
- `SHOPIFY_API_KEY`
- `SHOPIFY_API_SECRET`
- `SHOPIFY_REDIRECT_URI` (must exactly match the Shopify Dev Dashboard callback URL)
- Optional `SHOPIFY_SCOPES` (defaults to `read_orders`)

Never commit access tokens, API secrets, service-role keys, or MailerSend keys.

## OAuth routes
- `GET /auth?shop={shop}.myshopify.com` (requires authenticated Supabase bearer token)
- `GET /callback?shop=...&code=...&state=...&hmac=...`
- `GET /health`

## Launch gates still open
- Complete a real merchant OAuth install and verify all webhook registrations in that shop.
- Deliver an identifiable, consent-eligible checkout/cart event through Cloudflare → n8n → Supabase.
- Verify a legitimate recovery opportunity can be claimed and processed by `HENVALT_RECOVERY`.
- Verify MailerSend provider setup using the merchant's own credential in the dashboard. This must not be shared in chat.
- Only after explicit approval, perform a controlled end-to-end email test to an address the user controls. No production email is sent during setup.
- Verify a real recovered order and attribution before claiming recovered revenue or enabling performance billing.

The integration is not launch-ready until the launch gates above are verified. Synthetic webhook tests prove ingress and event persistence only; they do not prove recovery or revenue.
