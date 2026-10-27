# HENVALT Shopify integration

## Status
- GitHub write access verified.
- Additive Supabase OAuth-state migration applied.
- Service-role-only OAuth finalization RPC applied; stores Admin API token in Supabase Vault and links the shop.
- OAuth Edge Function source added here; deployment and Shopify credentials are still pending.
- Webhook ingress worker source is included for review; production Cloudflare Worker remains the deployed source of truth until a reviewed deployment succeeds.

## Required Supabase Edge Function secrets
Set these in Supabase Dashboard → Edge Functions → Secrets:
- `SHOPIFY_API_KEY`
- `SHOPIFY_API_SECRET`
- `SHOPIFY_REDIRECT_URI` (exact deployed callback URL)
- Optional `SHOPIFY_SCOPES` (default `read_orders`)

Never commit access tokens, API secrets, service-role keys, or MailerSend keys.

## OAuth routes
- `GET /auth?shop={shop}.myshopify.com`
- `GET /callback?shop=...&code=...&state=...&hmac=...`
- `GET /health`

The callback URL must exactly match Shopify Dev Dashboard. This implementation does not claim the app is launch-ready until callback, token persistence, webhook registration, and real event delivery are verified.
