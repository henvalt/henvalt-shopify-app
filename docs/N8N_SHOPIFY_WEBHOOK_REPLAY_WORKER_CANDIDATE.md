# Candidate n8n Shopify webhook replay worker

Status: design/patch specification only. No active workflow or draft was modified.

## Required architecture (keep exactly three workflows)

- `HENVALT_INGEST`: verify Shopify HMAC, resolve tenant, atomically persist the webhook plus replay job, and return a truthful HTTP response. Shopify processing becomes queue-driven after the response; do not run inline processing and replay-worker processing concurrently.
- `HENVALT_RECOVERY`: claim both `execute_intervention` and `process_shopify_webhook` jobs, route by `job_type`, and retain the existing intervention branch unchanged.
- `HENVALT_DELIVERY`: unchanged; only the existing authorized delivery workflow may send.

## HENVALT_INGEST ingress cutover

1. Replace the current serial `Verify Shopify HMAC`, `Resolve Shopify Tenant`, and `Supabase Ingest RPC` calls with one `Receive Shopify Webhook` HTTP Request node calling `/rest/v1/rpc/receive_shopify_webhook_v1`.
2. Map the candidate normalizer's shop domain, topic, delivery ID, HMAC, exact raw-body base64, parsed payload, and metadata. The RPC verifies the signed raw bytes, checks the parsed payload matches those bytes, resolves the active tenant, and atomically persists the webhook plus replay job.
3. Treat the returned `http_status` as the application response code; the HTTP status from PostgREST itself is not enough. Map 200/401/404/422/503 to the corresponding Shopify response.
4. Add explicit response handling for invalid HMAC, missing verifier secret, unknown tenant, malformed payload, and durable acceptance. Every path must send exactly one response; do not hard-code 200.
5. After a durable 200 response, stop the Shopify branch. Do not continue into canonical-event processing in parallel with the recovery worker. The replay worker becomes the single processing owner for Shopify events. Keep non-Shopify internal-event handling separate.

## Exact response-node contract

The installed n8n node type definitions were checked before specifying these parameters:
- Webhook node: `responseMode: "responseNode"`.
- Respond to Webhook node: `respondWith: "json"`, `responseBody: "={{ $json.__body }}"`, `options.responseCode: "={{ $json.__http }}"`, and `enableResponseOutput: true`.
- Route the response output through a source-mode gate. Shopify ingress terminates after the response; it must not flow into the old inline processing branch. Only separately authorized internal events may continue through their existing synchronous branch.
- All malformed-event, HMAC, tenant, and ingest outcomes must converge on the same response contract, with no double-response path.
- The receive-RPC HTTP Request node uses the existing Supabase API credential, `fullResponse: true`, `neverError: true`, and a bounded timeout that fits inside the Cloudflare 3.5-second upstream budget. Its body fields are `p_shop_domain`, `p_topic`, `p_delivery_id`, `p_hmac`, `p_raw_body_base64`, `p_payload`, and `p_metadata`, sourced from the candidate normalizer.

## HENVALT_RECOVERY patch

1. Change the claim query to:
   `SELECT * FROM henvalt.claim_next_job($1, ARRAY['execute_intervention','process_shopify_webhook']::text[])`
2. Replace the intervention-only guard with job-type-aware validation:
   - `execute_intervention`: require a valid `intervention_id`.
   - `process_shopify_webhook`: require a UUID `payload.webhook_id`.
   - Reject every unknown job type.
3. Add a Switch on `job_type`; the existing intervention output must connect to the current `Atomic Claim Intervention` node without behavior changes.
4. The replay output calls `henvalt.load_shopify_webhook_replay_job(job_id, worker_id)` using the claimed job identity. If `webhook_processed=true`, complete the claimed job and stop.
5. Otherwise call the dedicated replay-processing entry in `HENVALT_INGEST` with only `job_id` and `worker_id`. Do not pass an untrusted tenant ID or raw payload from the worker itself.
6. Complete the job only after the ingest subflow confirms `mark_webhook_processed=true`. On transient failures call `retry_job(job_id, worker_id, error, bounded_delay)`; on exhausted retries use the existing DEAD_LETTER state and an operator-visible alert/reconciliation path.

## HENVALT_INGEST replay entry

Add an `Execute Workflow Trigger` dedicated to replay jobs. It must:
1. Call `load_shopify_webhook_replay_job(job_id, worker_id)` again (defense in depth).
2. Stop with an idempotent success if the row is already PROCESSED.
3. Reconstruct the normalized event from the trusted stored `payload`, `topic`, `source_event_id`, tenant and metadata using the candidate normalizer.
4. Skip external HMAC verification only because the service-role-only loader verifies the durable `ingress_hmac_verified=true` marker written by the single-round-trip ingress RPC. Never accept a caller-provided “verified” boolean.
5. Skip tenant resolution only because the loader returns the tenant ID bound to the claimed job and webhook row.
6. Reuse the existing canonical-event, identity, checkout/order, eligibility, intervention, attribution and ledger pipeline.
7. Mark the webhook PROCESSED only after every required downstream operation completes. On failure, mark it FAILED and return a structured retryable error to the recovery worker.

## Concurrency and acknowledgement

- Do not let the live Shopify ingress continue through the existing processing branch after enqueue while the recovery worker is allowed to claim the same job. The queue must have one processing owner.
- A processed duplicate may return 200 without a new job. An in-flight duplicate may return 200 only if its existing replay job is active.
- HMAC mismatch returns 401; missing verifier secret/configuration returns 503; unknown tenant returns 404; malformed payload returns 422; persistence/queue failure returns 503.
- Every branch must terminate in exactly one explicit HTTP response. A Respond to Webhook node must not be placed only on the post-ingest success path.

## Acceptance cases before staging

- New Shopify delivery: durable row + queued replay job before HTTP 200.
- Same delivery ID repeated: one webhook row and one replay job.
- Distinct delivery IDs with same event correlation ID: two webhook rows/jobs.
- Missing delivery ID: reject; no fallback to body/event correlation ID.
- Invalid HMAC: no webhook row or replay job.
- Missing HMAC secret: retryable 503.
- Unknown tenant: no ingest row; 404.
- Queue insert fails: transaction rolls back webhook row; 503.
- Worker receives a job with wrong worker ID/tenant/webhook ID: fail closed.
- Already-processed event: job completes without repeating downstream side effects.
- Transient downstream failure: bounded retry; no duplicate opportunity or delivery.
- Exhausted retry: dead letter, alert and operator replay path.
- Full end-to-end synthetic Shopify event in isolated staging: canonical event, customer/checkout, opportunity, intervention, delivery request, and order attribution/ledger paths verified; sender remains disabled until separately approved.

## Why this is not a quick one-node patch

The active recovery worker assumes every job has an intervention ID, while the existing ingest workflow's downstream nodes depend on its webhook-trigger context. Simply adding a second job type or a new trigger would either drop the job at the guard or bypass context/tenant/idempotency controls. The single-round-trip ingress RPC is validated in disposable PostgreSQL, but its n8n node wiring, explicit response node, queue-only processing cutover, and replay subflow are not yet implemented. The patch must be applied and tested as one isolated workflow graph before staging.
