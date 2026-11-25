# Active Cloudflare Shopify ingress audit — 25 November 2026

**Result: PRODUCTION INGRESS STILL HAS AN EARLY-ACKNOWLEDGEMENT GAP.**
**Disposition: NO-GO for Shopify webhook/replay cutover until the candidate Worker and candidate n8n ingress are validated together in isolated staging.**

## Deployed Worker identity (read-only inspection)

- Worker script: `henvalt-clean-ingress-v1`
- Cloudflare annotation: `Correct HENVALT_INGEST production webhook destination`
- Last modified: `2026-10-31T17:18:20.463211Z`
- Deployed script tag: `1ff4fe4964c149b2b877bfbfa3a27134`
- Deployed ETag: `95e4ad24e08e04f767f64989aae664661361d2c6ab899021c0d46a0de12cf623`
- Ingress binding: `N8N_INGEST_URL` targets the existing production n8n `/webhook/henvalt/ingest` endpoint.
- Secret binding names observed: `SHOPIFY_API_SECRET`; no secret value was read or recorded.

## Observed live acknowledgement behavior

The deployed script:
1. Reads the raw request body.
2. Verifies `X-Shopify-Hmac-Sha256` using the bound Shopify secret.
3. Requires a valid `*.myshopify.com` shop, topic and `X-Shopify-Webhook-Id`.
4. Forwards the raw body and selected Shopify headers to the configured n8n endpoint.
5. Returns `502` when fetch throws or `forwarded.ok` is false.
6. Otherwise returns `200` with `{ ok: true, accepted: true, topic, webhook_id }`.

The live Worker does not parse the upstream response body, require a durable webhook UUID, require a replay-job UUID/status, or distinguish a generic upstream `202`/empty `204` from a committed queue acknowledgement. An upstream `2xx` is currently sufficient for Shopify to stop retrying.

## Cross-system consequence

The read-only active n8n INGEST snapshot independently shows `responseMode: onReceived` and no Respond to Webhook node. Thus the current deployed path can acknowledge Shopify before the n8n HMAC/tenant/durable-ingest path finishes. The Cloudflare Worker then treats that early n8n `2xx` as accepted.

This confirms the issue exists in the deployed path; it is not merely a candidate-design concern.

## Candidate correction already present on the branch

The repository candidate `cloudflare/worker.js` now:
- requires an exact upstream HTTP 200;
- parses a valid JSON acknowledgement;
- requires a durable webhook UUID;
- accepts `duplicate` only with durable webhook identity;
- for accepted/replay-accepted/already-processing outcomes, requires a replay-job UUID and an active replay-job status;
- returns retryable `503` for malformed, generic, non-durable, unknown or terminal acknowledgements.

The candidate n8n ingress contract uses a single-round-trip durable receive RPC and explicit response handling. Candidate regression tests cover empty 204, empty 200, malformed JSON, generic accepted JSON, missing IDs, terminal replay state, HTTP 202, and valid durable responses.

**The candidate Worker has not been uploaded or deployed.** The candidate n8n workflow has not been imported, executed or published. No live resource was modified during this audit.

## Required cutover gates

1. Obtain an isolated Supabase + n8n staging identity; production cannot be reused.
2. Apply candidate migrations only to that isolated database and validate the complete schema, roles, Vault and Edge Functions.
3. Import the inactive three-workflow candidates into an isolated n8n workspace; prove every Shopify ingress branch emits exactly one truthful response.
4. Connect the staging Worker only to the staging n8n endpoint; prove durable acceptance and retry behavior with synthetic signed payloads.
5. Prove replay claims, leases, tenant binding, all business writes, payment deferral, completion/retry/dead-letter behavior and delivery no-send controls.
6. Only after owner approval, deploy the Worker and n8n cutover as a coordinated change. Do not deploy the Worker alone: it depends on the matching durable acknowledgement contract.

## Safety boundary

This audit was read-only. No Worker upload, route/domain change, secret read, n8n mutation/execution, Supabase migration, Shopify release, email, charge, or production data write occurred.


## Production activity and database-advisor cross-check (read-only)

### n8n execution metadata since 1 November 2026

- `HENVALT_INGEST`: 0 execution records.
- `HENVALT_DELIVERY`: 0 execution records.
- `HENVALT_RECOVERY`: 10,004 execution records (10,003 successful scheduled executions and 1 error).
- The most recent observed recovery execution succeeded at `2026-11-25T12:44:28Z`; the single observed error was on `2026-11-18T17:48:28Z`.
- The error execution was inspected metadata-only. No node input/output data or customer payload was retrieved.

This does not prove that no Shopify webhooks reached Supabase by another path. It does prove that the connected n8n INGEST and DELIVERY workflows have no execution records in this window, while the minute scheduler continues to run.

### Supabase advisor results (25 November 2026)

- Health advisor: no findings.
- Security advisor: 11 RLS-enabled tables have no policies. A separate privilege query found no direct `anon`, `authenticated` or `PUBLIC` table grants on those 11 tables; the warning is not evidence of direct table access by itself.
- Security advisor also flags `henvalt.is_tenant_member(uuid)` as SECURITY DEFINER and executable by `authenticated`. Do not revoke it blindly: inspect its use in RLS policies and intended boolean membership-check contract before changing privileges.
- Supabase Auth leaked-password protection is disabled. This is an Auth configuration decision, not a SQL migration; it remains an owner security-hardening item.
- Performance advisor reports one unindexed foreign key on `henvalt.shopify_privacy_requests.tenant_id`. Candidate migration `202611210012_shopify_privacy_tenant_fk_index.sql` adds the covering index, but it is not applied to production.
- The advisor lists 63 unused indexes. With no current ingress/delivery workload, do not drop indexes based on that signal alone.

No production setting, privilege, index, workflow or Worker was changed during these checks.
