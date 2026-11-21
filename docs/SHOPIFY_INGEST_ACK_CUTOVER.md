# Shopify ingress acknowledgement and replay cutover

Status: **release blocker identified by read-only inspection**. This is a candidate-only cutover specification; it does not change the active n8n workflows or production database.

## Observed active configuration

Read-only inspection of active workflow `HENVALT_INGEST` (workflow ID `VTpfGKNtu1CSQ4Rv`, active version `6368d539-708f-494a-8be8-b9601d0e8607`) found:

- Webhook path: `POST /henvalt/ingest`
- `rawBody: true`
- `responseMode: onReceived`
- No `Respond to Webhook` node in the active workflow.
- Current path: normalization → HMAC verification → Shopify tenant resolution → tenant binding/validation → `ingest_raw_webhook_v2` → `Classify Result` → `Should Process?`.
- `HMAC Verified?` false output has no connected response node.
- `Is Valid` false output reaches `Reject Invalid Event` (`stopAndError`), not an HTTP response node.
- The active classifier maps a generic HTTP 409 to `200 duplicate` without requiring a durable webhook ID.\n- The active normalizer prioritizes `X-Shopify-Event-Id` ahead of `X-Shopify-Webhook-Id` for its event identity.

With `onReceived`, n8n can acknowledge before HMAC verification and before durable ingestion. That is a delivery-acceptance gap.

## Shopify delivery identity defect

Read-only inspection of the live `Validate & Normalize` node found this current event-ID precedence: `body.event_id` → `X-Shopify-Event-Id` → `X-Shopify-Webhook-Id` → `body.id`. That is unsafe for delivery deduplication. Shopify documents `X-Shopify-Webhook-Id` as the unique delivery ID and `X-Shopify-Event-Id` as a correlation ID shared across deliveries from the same merchant action (including separate subscriptions). The normalizer must use `X-Shopify-Webhook-Id` as `source_event_id` and in the idempotency key; retain `X-Shopify-Event-Id` only in metadata for correlation. Do not fall back to the event ID when the delivery ID is absent.

The candidate Cloudflare worker now requires `x-shopify-webhook-id` and no longer accepts `x-shopify-event-id` as a substitute. A regression test verifies that an event ID alone is rejected before forwarding. The live n8n normalizer still needs the precedence correction before release.

## Candidate n8n normalizer patch

A candidate replacement Code-node script is stored at `n8n/shopify-ingest-normalizer-candidate.js`, copied from the inspected active `Validate & Normalize` node and changed only at the identity boundary:
- For `source === "shopify"`, `event_id` and `source_event_id` now come only from `X-Shopify-Webhook-Id`.
- `X-Shopify-Event-Id` remains metadata for cross-delivery correlation.
- Shopify idempotency is `shopify:{shop_domain}:{webhook_id}`; it no longer uses the topic plus an event correlation ID or an arbitrary body field.
- Missing Shopify delivery ID is an invalid event; it cannot fall back to `body.event_id`, `body.id`, or `X-Shopify-Event-Id`.
- Non-Shopify internal event identity remains unchanged.

The test `tests/shopify-ingest-delivery-identity.test.mjs` executes this candidate code in an isolated Node VM and covers differing body/event IDs, shared correlation IDs across separate deliveries, missing delivery ID, and internal event compatibility. It is wired into the safety CI. This candidate script is not written to the active n8n workflow.

## Critical post-ack recovery finding

A fast 200 is necessary for Shopify's webhook deadline, but it is safe only if durable asynchronous processing is guaranteed:

- Shopify's official delivery guidance says the endpoint must respond within five seconds; failed deliveries are retried up to eight times over four hours. A 2xx response is considered successful, so later application-processing failures are not retried by Shopify. See the official verification and troubleshooting docs.
- Active `HENVALT_RECOVERY` calls `claim_next_job` with only `execute_intervention`; it does not claim Shopify webhook processing jobs.
- Its `Repair Stale Work` node calls `requeue_stale_jobs(900)` and `recover_stale_interventions(900)`. This repairs background jobs/interventions, not arbitrary failed `webhook_events`.
- `reconcile_deferred_payment_webhooks` handles only `order_transactions/create` rows explicitly marked `payment_reconciliation_pending`; it is not a general Shopify webhook replay worker.
- `mark_webhook_failed` only sets the webhook row to `FAILED`, stamps `processed_at`, and records `processing_error`. It does not enqueue a retry or increment a retry counter.
- `ingest_raw_webhook_v2` can reclaim an old failed/in-flight row when Shopify sends the same delivery again. That is not sufficient after HENVALT has already returned 200, because Shopify stops retrying successful deliveries.
- Read-only status aggregation found two current `FAILED` webhook rows: one was a privilege probe, and one checkout event failed because required checkout/customer data was missing. No rows were modified.

**Conclusion:** an early 200 immediately after inserting only `webhook_events` is not yet safe. The accepted row needs an atomic, independently claimable replay job, the delivery ID must be used for deduplication, and the existing three-workflow architecture needs a worker path that actually processes it.

## Required candidate architecture — keep exactly three workflows

### 1. Atomic durable enqueue at ingress

Shopify's five-second end-to-end delivery deadline means the ingress path should avoid serial network round trips. The candidate Cloudflare worker now caps its n8n upstream wait at 3.5 seconds, leaving response-time margin for edge and network overhead; it returns retryable 503 on timeout. The candidate n8n ingress should combine HMAC verification, active tenant resolution, webhook persistence and replay-job enqueue into one service-role-only RPC (for example, `receive_shopify_webhook_v1`) so the success response is both durable and fast. The existing separate RPCs are useful primitives, but three sequential PostgREST calls make the five-second target harder to meet.

Use the new candidate-only `henvalt.ingest_shopify_webhook_with_replay_job(...)` wrapper (migration `202611210005_shopify_webhook_replay_enqueue.sql`). It calls the existing `ingest_raw_webhook_v2` and inserts the replay job in the same outer database transaction. It does not modify the active production RPC. The wrapper must:

1. Verifies the tenant and accepts the authenticated event only after HMAC and tenant resolution.
2. Inserts or idempotently finds the `webhook_events` row.
3. For a new or reclaimable unprocessed event, inserts/upserts a `background_jobs` row with job type `process_shopify_webhook`, payload containing only the webhook row ID and required correlation/tenant context, and an idempotency key derived from the webhook ID.
4. Returns `webhook_id`, `should_process`, `processing_status`, `replay_job_id`, and `replay_job_status` from the same transaction boundary.
5. Does not return an accepted response if the job could not be durably queued.

The existing `background_jobs` table already has tenant, payload, status, attempts, max_attempts, lock lease, retry timing, last_error and idempotency fields. Existing `claim_next_job`, `retry_job`, `complete_job`, and `requeue_stale_jobs` provide reusable primitives, but their current live worker usage is limited to intervention jobs.

### 2. Ingress response contract

In a candidate staging workflow:

1. Set the webhook response mode to `responseNode`.
2. Route every pre-ingest rejection to an explicit response envelope: actual invalid HMAC → 401; missing HMAC secret/verifier outage → 503; unknown tenant → 404; malformed event → 422; tenant lookup/RPC infrastructure failure → 503.
3. Route the success classifier to the shared `Acknowledge Ingress Request` response node.
4. Return 200 for a new event only when the ingest RPC returns a durable webhook ID, an explicit `should_process` decision, and an active replay job ID/status.
5. Return 200 for a duplicate already marked `PROCESSED` when the durable webhook ID is present.
6. Return 200 for a duplicate still `PROCESSING` only when its durable replay job is verifiably `QUEUED`, `CLAIMED`, `RUNNING`, or `RETRY_WAIT`.
7. Return 503 for generic 409, missing webhook ID, missing processing decision, missing/inactive replay job, timeout, network error, or backend 5xx. Never infer a duplicate from a status code alone.
8. End the webhook execution after the response. Do not continue the old synchronous processing chain in parallel with the replay worker.

### 3. Replay processing inside the existing workflows

Keep the three-workflow limit:

- `HENVALT_RECOVERY`: extend `claim_next_job` worker types to include `process_shopify_webhook`. Add a job-type branch; intervention jobs keep their current path, webhook jobs enter the replay path. Retry through the existing job lease/backoff primitives and dead-letter after the configured attempt limit.
- `HENVALT_INGEST`: add a private Execute Sub-workflow Trigger path for replayed webhook jobs. It must load the stored webhook row through a service-role-only RPC that validates the claimed job ID/worker lease; never trust a tenant ID or raw payload supplied by an external caller. Rehydrate the normalized event from the stored payload/metadata and run the existing canonical event, opportunity, eligibility and intervention logic.
- `HENVALT_INGEST`: mark the webhook row `PROCESSED` only after its downstream processing reaches a terminal successful/intentional-no-op outcome. On transient failure, mark it failed and schedule the replay job retry. On permanent invalid/business-rule outcomes, record an explicit terminal reason and complete the job without attempting unsafe recovery.
- `HENVALT_DELIVERY`: remains unchanged; it continues to own provider delivery and tracking.

The replay path must be idempotent across duplicate job claims and worker crashes. If a worker dies after downstream processing but before job completion, the retry must detect already-completed webhook processing and safely complete the job without creating a second opportunity/intervention.

### 4. n8n response-node runtime constraints

The n8n Respond to Webhook documentation states that if a workflow finishes without executing a Respond node, n8n returns a standard 200; if it errors before the first Respond node executes, n8n returns 500; and a later second Respond node is ignored. Therefore, setting `responseMode: responseNode` alone is not fail-closed: every normal branch must reach exactly one explicit response node with its status set, and every error path before it must be handled or deliberately produce a retryable 5xx.

## Read-only database contract verification

The connected production database was inspected with SELECT-only catalog/function-definition queries; no data or schema was changed:

- `henvalt.verify_shopify_webhook_hmac(text,text)` returns a boolean and its execute ACL is limited to `service_role` and `postgres`. Its current implementation returns `false` both for a bad signature and when the Vault secret is missing/empty; the candidate ingress RPC must distinguish those cases so a configuration outage becomes retryable 503 rather than a permanent 401.
- `henvalt.resolve_shopify_tenant(text)` returns a UUID or NULL for an unmapped/inactive shop; its execute ACL is limited to `service_role` and `postgres`.
- `henvalt.ingest_raw_webhook_v2(...)` returns `webhook_id`, `is_duplicate`, `should_process`, and `processing_status`; its execute ACL is limited to `service_role` and `postgres`.
- The active production `ingest_raw_webhook_v2` locks matching idempotency rows and inserts a new webhook row with `PROCESSING` state, but it does not create a `process_shopify_webhook` job or return a replay job ID. Candidate migration `202611210005_shopify_webhook_replay_enqueue.sql` adds a service-role-only wrapper that atomically ensures the job exists and returns its ID/status.
- `claim_next_job` supports caller-supplied job-type filters, but the active recovery workflow currently filters to `execute_intervention` only. A read-only aggregate of `background_jobs` found only `execute_intervention` and a historical `HENVALT_TEST_JOB`; no `process_shopify_webhook` jobs exist.

## Acceptance matrix

| Scenario | Expected response / outcome | Requirement |
|---|---|---|
| New event + atomic replay job | 200 | Durable webhook row and active replay job exist first |
| Missing `X-Shopify-Webhook-Id` | 400 | Do not substitute `X-Shopify-Event-Id` |\n| Multiple subscriptions share one event ID | Distinct delivery IDs | Deduplicate on `X-Shopify-Webhook-Id`, correlate with `X-Shopify-Event-Id` |
| Duplicate already processed | 200 | Existing durable row |
| Duplicate processing with active replay job | 200 | Existing durable job lease/state |
| Duplicate processing without active replay job | 503 | Do not hide a stranded event |
| Generic HTTP 409 without durable row/job | 503 | Never infer duplicate from status alone |
| Invalid HMAC | 401 | Reject before tenant lookup/ingest |
| HMAC secret/verifier unavailable | 503 | Retryable configuration/backend failure, not a bad-signature 401 |
| Tenant mapping missing | 404 | HMAC verified; no tenant guessed |
| Tenant lookup infrastructure failure | 503 | Retryable; not mislabeled as unknown tenant |
| Malformed/incomplete event | 422 | Explicit rejection response |
| Ingest RPC or enqueue unavailable | 503 | No success acknowledgement |
| Replay worker transient failure | Job retry | Bounded backoff; webhook remains recoverable |
| Replay worker exhausted retries | Dead letter | Visible operational alert/reconciliation path |
| Worker crashes after processing | Safe idempotent completion | No duplicate opportunity/intervention |

## Implementation cautions

- Do not acknowledge immediately after `ingest_raw_webhook_v2` until the replay job is atomically confirmed.
- Do not put the shared response node only after `Classify Result`: that misses the current HMAC-false and validation-false branches.
- Do not use `stopAndError` for a webhook branch that must return a defined HTTP status.
- Do not run the old synchronous processing branch and the replay worker in parallel for the same event.
- Do not treat `PROCESSING` alone as proof that an active worker exists; require an active durable job state.
- Do not return 200 for a generic 409 or for a row with no durable webhook ID.
- Confirm a single explicit HTTP response for every request path and prove the replay worker's retry/dead-letter behavior in isolated staging.

## Safety boundary

This document, candidate contract code, migration `202611210005_shopify_webhook_replay_enqueue.sql`, disposable PostgreSQL fixture/acceptance tests and regression snapshots are branch-only. No production n8n workflow, Supabase object, Cloudflare Worker, Shopify app release, or email sender was changed. Isolated staging validation is still required before any cutover.
