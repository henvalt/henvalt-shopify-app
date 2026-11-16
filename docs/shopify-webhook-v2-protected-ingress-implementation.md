# V2 Shopify webhook ingress: Worker → protected Edge Function → Vault-backed inbox

Status: branch-only implementation preparation. Nothing in this document authorizes deployment, secret configuration, migration application, OAuth changes, or Shopify webhook re-registration.

## Architecture

```text
Shopify delivery
  POST /shopify/webhooks/<per-install opaque route token>
       |
       v
Cloudflare Worker (public ingress)
  - validates required Shopify headers and body size
  - does not hold the Shopify app secret for V2
  - does not hold the Supabase service-role key
  - forwards exact raw bytes + allowlisted Shopify metadata
  - authenticates to the Edge Function with a dedicated internal bearer token
       |
       v
Supabase Edge Function: henvalt-shopify-webhook-ingress
  - validates internal bearer token
  - uses its server-side SUPABASE_SERVICE_ROLE_KEY
  - calls henvalt.accept_shopify_webhook_v2
       |
       v
Postgres SECURITY DEFINER RPC
  - hashes route token and resolves exact connection + app
  - reads that app's secret from Vault internally
  - verifies Shopify HMAC over exact raw body bytes
  - checks shop domain and shop_id where present
  - inserts idempotent durable receipt
       |
       v
HTTP 200 only after receipt insert or confirmed duplicate
```

The Worker never receives the service-role key or the Shopify app secret. The Edge Function's internal bearer token is separate from Shopify credentials and is only a Worker-to-Edge authentication credential. It must be configured as a secret on both runtimes at a later, separately approved deployment step.

## Branch files

- `cloudflare/worker.js`: adds a distinct route shape `/shopify/webhooks/<route-token>`; leaves the legacy `/shopify/webhooks` route wired to the existing legacy verifier and n8n endpoint.
- `supabase/functions/henvalt-shopify-webhook-ingress/index.ts`: validates internal bearer authentication, reads raw request bytes, calls the database RPC using the Edge Function's server-side service-role key, and returns only safe receipt status.
- `supabase/migrations/202611160002_shopify_webhook_verified_inbox_rpc.sql`: Vault-backed HMAC verification and durable receipt persistence. Depends on the preceding identity-foundation migration.
- Static tests cover Worker routing, exact raw-byte forwarding, failure behavior, Edge Function authentication and RPC contract.

## Required future runtime configuration

Worker:
- `SUPABASE_WEBHOOK_INGRESS_URL`: exact deployed Supabase Edge Function URL.
- `HENVALT_INGRESS_AUTH_TOKEN`: high-entropy internal bearer secret shared only with the Edge Function.
- Legacy bindings `SHOPIFY_API_SECRET` and `N8N_INGEST_URL` remain for the old route until a separate cutover.

Supabase Edge Function:
- `HENVALT_INGRESS_AUTH_TOKEN`: same internal bearer secret.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`: Supabase-managed server-side runtime values. The service-role key must never be copied to Cloudflare or Shopify.

Shopify app registry:
- Each app registry row must reference its own Vault secret name in `webhook_secret_ref`.
- The RPC reads the decrypted value internally and never returns it.
- Each Shopify connection must be assigned to the correct app key, and each connection needs a high-entropy per-install route token whose SHA-256 hash alone is stored in Postgres.
- The raw route token is returned only during secure provisioning and used in the webhook callback URL. It must never be logged or persisted in clear text.

## Safety and cutover gates

1. Apply neither migration until both SQL files have been reviewed and tested against a disposable PostgreSQL database with the same extensions, schema and grants.
2. Seed the app registry only after the correct app identities and Vault secret references are independently verified.
3. Add a transaction-safe OAuth provisioning function to create/rotate the per-connection route token and return the raw token exactly once.
4. Add app-aware webhook subscription registration in the OAuth flow, using the unique route URL, while preserving the current callback subscriptions until explicit cutover.
5. Configure the dedicated Worker↔Edge bearer secret in both runtimes; do not reuse a Shopify secret or expose service-role credentials.
6. Run valid-HMAC, invalid-HMAC, altered-domain, altered-shop-ID, duplicate-delivery, revoked-token, expired-token and inactive-app tests against a non-production environment.
7. Add an inbox consumer/adapter that transforms only verified receipts into the existing canonical event pipeline with exact connection lineage. Do not connect the new inbox directly to tenant-only legacy writers.
8. Only after all gates pass and separate approval, deploy the Edge Function/Worker and update Shopify callback registrations.

## Important limitations

- The Edge Function and Worker source here are not deployed.
- The SQL RPC and its prerequisite migration are not applied or database-engine tested.
- The per-install route token is not yet issued by OAuth and no Shopify webhook callback currently uses this V2 path.
- The inbox has no consumer yet; a verified receipt is durable intake, not a completed recovery event.
- The legacy callback, active n8n workflow and existing production webhook subscriptions remain unchanged.
- Static CI passing does not prove real Shopify delivery or production configuration.
