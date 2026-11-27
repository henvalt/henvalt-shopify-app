# Supabase-backed Shopify staging ingress candidate

**Status:** candidate code and CI only; not deployed. Staging no-send remains enabled.
**Branch:** `feat/shopify-connection-scoped-ingress`.

## Why this candidate exists

The prior staging ingress Worker forwarded signed Shopify webhook requests to an n8n host placeholder. The partner-owned n8n workspace is no longer accessible, and the current placeholder is deliberately rejected. This candidate removes the n8n dependency from the ingress boundary without changing the production Worker or the three-stage business architecture.

## Request path

1. Shopify sends a webhook to the Cloudflare Worker at `POST /shopify/webhooks`.
2. The Worker validates bounded request size, shop-domain syntax, topic, delivery ID and required HMAC header. It forwards only an allowlist of Shopify headers and the unchanged raw request body.
3. The Worker sends the request to the isolated Supabase Edge Function using a dedicated `HENVALT_INGRESS_SHARED_SECRET`. It does not hold a Supabase service-role key.
4. The Edge Function checks the shared secret in constant time, parses the original body, and calls the service-role-only `henvalt.receive_shopify_webhook_v1` RPC.
5. The database verifies Shopify HMAC against the Vault secret, resolves the active store connection, and atomically persists the webhook plus its replay job.
6. The Worker acknowledges only a confirmed durable duplicate or an accepted webhook with an active replay job. Any missing or ambiguous acknowledgement returns retryable 503.

## Secret boundaries

- Cloudflare Worker: staging-only `HENVALT_INGRESS_SHARED_SECRET`.
- Supabase Edge Function: the same staging-only shared secret plus the Supabase-provided service-role key.
- Database Vault: `henvalt_shopify_app_secret` for the staging Shopify app HMAC verification.
- The Supabase service-role key is never placed in Cloudflare Worker configuration.
- No production credentials or endpoints are accepted by the staging Worker configuration.

## No-send safety

- Worker and Edge Function both require `HENVALT_STAGE_NO_SEND=true`.
- The staging project provider-send interlock was read-only verified OFF.
- This ingress path only persists a webhook and replay job; it does not send email, invoke MailerSend, charge billing, or call Shopify Admin APIs.
- No n8n workflow is imported or activated by this candidate.
- No Cloudflare Worker, Supabase Edge Function, secret, route, database migration, Shopify app, or production resource was deployed or changed.

## Candidate tests

- Cloudflare Worker configuration is pinned to staging project ref `xidhtmrfvsgfmyltjuja`.
- Worker tests cover the exact staging host, shared-secret forwarding, raw-body preservation, durable acknowledgement requirements and fail-closed behavior.
- Edge handler tests cover shared-secret rejection, production-project rejection, service-role-only RPC invocation, raw-body/HMAC forwarding, replay-job confirmation and malformed payload rejection.
- CI type-checks the Edge Function and runs both Node contract suites.

## Deployment prerequisites — currently missing

1. A staging Shopify app Client ID and app secret owned by the HENVALT owner.
2. A staging-only Vault secret named `henvalt_shopify_app_secret` with that app secret. Current staging audit reports it is absent.
3. A fresh random shared secret provisioned in both the Cloudflare Worker and Supabase Edge Function secret stores.
4. A valid staging Shopify development store and owner account.
5. OAuth Edge Function configuration and a staging dashboard URL.
6. A controlled deploy to staging followed by a signed synthetic webhook test.

Do not register Shopify webhooks or install the app until the staging OAuth and ingress endpoints are deployed and verified. Do not deploy this candidate to production.
