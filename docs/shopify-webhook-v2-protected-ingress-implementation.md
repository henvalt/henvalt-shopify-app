# V2 Shopify webhook ingress: Worker → protected Edge Function → Vault-backed inbox

Status: candidate implementation on the preparation branch only. Nothing here authorizes production migration application, secret configuration, deployment, Shopify re-registration, or n8n cutover.

## Architecture

```text
Shopify delivery
  POST /shopify/webhooks/<per-install opaque route token>
       |
       v
Cloudflare Worker
  - bounds the raw body and validates required headers
  - forwards exact raw bytes and allowlisted metadata
  - authenticates to the Edge Function with a dedicated bearer
       |
       v
Supabase Edge Function: henvalt-shopify-webhook-ingress
  - authenticates the Worker
  - bounds the request and RPC response
  - accepts a verified receipt through accept_shopify_webhook_v2
  - dispatches supported topics to exact-store projection RPCs
       |
       v
Postgres SECURITY DEFINER RPCs
  - resolve exact connection + app from hashed per-install route token
  - verify app-specific Shopify HMAC over exact raw body bytes
  - persist idempotent receipt keyed by connection + delivery ID
  - project checkout, jurisdiction, consent, order and refund state
  - app/uninstalled receipt trigger deactivates only its exact connection
```

The Worker never receives the service-role key or Shopify app secret. The Edge Function's internal bearer is a separate Worker-to-Edge credential. All components remain candidate source until separately approved and deployed.

## Candidate branch implementation

- `cloudflare/worker.js`: distinct tokenized V2 route; legacy `/shopify/webhooks` route remains separately wired.
- `supabase/functions/henvalt-shopify-webhook-ingress/index.ts`: Worker authentication, 1 MB streaming request bound, 8-second RPC deadline, 32 KB bounded RPC response parser, safe failure handling and topic dispatch.
- `supabase/migrations/202611160001_shopify_webhook_identity_foundation.sql` and `202611160002_shopify_webhook_verified_inbox_rpc.sql`: app registry, per-install route tokens, exact-store receipt and Vault-backed raw-body HMAC verification.
- Checkout create/update dispatches to checkout identity projection and jurisdiction projection.
- Customer email marketing consent updates dispatch to the consent evidence projection.
- Order create/updated/paid/cancelled dispatch to the exact-store order lifecycle projection.
- Refund create dispatches to the exact-store refund projection.
- App uninstall is handled transactionally by the receipt-insert trigger in `202611170009_shopify_exact_store_uninstall_processor_v2.sql`; it deactivates only the exact connection and revokes its route/pixel capabilities.
- The OAuth V2 candidate registers and verifies only the topics above plus app uninstall. Cart create/update and order transaction create are deliberately not subscribed because their V2 webhook projections are not implemented. Cart/browse recovery currently has a separate pixel-event candidate path.
- Any unexpected/unhandled topic receives HTTP 422 rather than a false HTTP 200 acknowledgement.
- Tests cover verified inbox idempotency, exact-store checkout/order projection, bounded ingress acknowledgement, and OAuth subscription-to-handler coverage.

## Required runtime configuration (not verified)

Worker:
- `SUPABASE_WEBHOOK_INGRESS_URL`: exact deployed Supabase Edge Function URL.
- `HENVALT_INGRESS_AUTH_TOKEN`: high-entropy internal bearer secret shared only with the Edge Function.
- Legacy `SHOPIFY_API_SECRET` and `N8N_INGEST_URL` remain for the old route until an approved cutover.

Supabase Edge Function:
- `HENVALT_INGRESS_AUTH_TOKEN`: same internal bearer.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`: Supabase-managed server-side runtime values.

Shopify app registry:
- Each app registry row must reference its own Vault secret name in `webhook_secret_ref`.
- Each connection needs a high-entropy per-install route token; only its SHA-256 hash is stored.
- The raw route token is returned only during secure provisioning and used in the callback URL. It must never be logged or persisted in clear text.

## Remaining safety and cutover gates

1. Review and apply the candidate migrations only after production-parity disposable PostgreSQL, backup and rollback validation.
2. Independently verify the app registry identity and Vault secret reference for every app.
3. Configure and verify the Worker↔Edge bearer in both runtimes.
4. Deploy the Edge Function and Worker only after separate approval; verify actual signed Shopify deliveries, retry behavior, and all supported topics in a non-production store.
5. Verify each OAuth-created subscription against the exact tokenized callback URI and persist/read the registration audit.
6. Reconcile historical connection/store lineage before enabling recovery.
7. Keep the legacy n8n route and V2 route mutually exclusive during cutover; do not create duplicate Shopify subscriptions or duplicate provider sends.
8. Complete end-to-end event → candidate → claim → controlled delivery → signed provider event → order/refund attribution tests before any merchant launch.

## Important limitations

- Worker, Edge Function and candidate migrations are not deployed/applied in production.
- Production app registry rows, Vault secret references, route-token provisioning and actual Shopify V2 subscription receipts remain unverified.
- A verified receipt and its supported projections do not prove recovery candidate eligibility, delivery consent, successful sending, recovered-order attribution or fee correctness.
- Cart/browse webhook topics and order transaction webhooks are not currently registered by the V2 OAuth candidate; do not treat them as implemented.
- Legacy callbacks and all three active n8n workflows remain unchanged. Static CI is not production runtime proof.
