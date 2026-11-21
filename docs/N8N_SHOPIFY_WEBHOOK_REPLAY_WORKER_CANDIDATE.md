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

1. Preserve the existing intervention claim with `SELECT * FROM henvalt.claim_next_job($1, ARRAY['execute_intervention']::text[])`. Add a separate replay claim call to `henvalt.claim_shopify_replay_job(worker_id, 180)`. Never claim `process_shopify_webhook` through the generic claim RPC; it does not issue a fencing lease.
2. Replace the intervention-only guard with job-type-aware validation:
   - `execute_intervention`: require a valid `intervention_id`.
   - `process_shopify_webhook`: require a UUID `payload.webhook_id`.
   - Reject every unknown job type.
3. Add a Switch on `job_type`; the existing intervention output must connect to the current `Atomic Claim Intervention` node without behavior changes.
4. The replay output calls `henvalt.load_shopify_webhook_replay_job(job_id, worker_id, lease_id)` using the exact lease returned by the replay claim RPC. If `webhook_processed=true`, complete the claimed job and stop.
5. Otherwise call the dedicated replay-processing entry in `HENVALT_INGEST` with only `job_id`, `worker_id`, and the exact `lease_id` returned by the claim. The lease token is required for the subflow's second fenced load; do not pass an untrusted tenant ID or raw payload from the worker itself.
6. Complete the replay job only after the ingest subflow confirms `mark_webhook_processed=true`, using `complete_shopify_replay_job(job_id, worker_id, lease_id)`. On transient failures call `retry_shopify_replay_job(job_id, worker_id, lease_id, error, bounded_delay)`; on exhausted retries the RPC sets DEAD_LETTER. Keep the existing `complete_job` / `retry_job` calls for the intervention branch only.

## HENVALT_INGEST replay entry

Add an `Execute Workflow Trigger` dedicated to replay jobs. It must:
1. Call `load_shopify_webhook_replay_job(job_id, worker_id, lease_id)` again (defense in depth). Migration 008 revokes the two-argument loader from `service_role`; no replay subflow may call it.
2. Stop with an idempotent success if the row is already PROCESSED.
3. Reconstruct the normalized event from the trusted stored `payload`, `topic`, `source_event_id`, tenant and metadata using the candidate normalizer.
4. Skip external HMAC verification only because the service-role-only loader verifies the durable `ingress_hmac_verified=true` marker written by the single-round-trip ingress RPC. Never accept a caller-provided “verified” boolean.
5. Skip tenant resolution only because the lease-fenced loader returns the tenant ID bound to the claimed job and webhook row. The subflow must keep the same `lease_id` for any lease renewal and must stop before downstream commits if renewal returns NULL.
6. Treat the lease as a heartbeat contract, not a one-time check. Before each potentially long-running or mutating pipeline stage (canonical event, identity/customer projection, checkout/order projection, eligibility/opportunity, intervention enqueue, attribution/ledger), renew the same lease and require a non-NULL expiry before starting that stage. Keep stage calls sequential; never fan out mutating work in parallel. Set each individual database/API operation timeout below the remaining lease budget and renew again before the next stage. If renewal fails, stop immediately, return a retryable lease-lost result, and do not begin another downstream mutation.
7. Downstream stage RPCs must remain idempotent by tenant + source webhook/event identity. A lease heartbeat reduces overlap but is not itself a transaction lock over all downstream systems; do not claim strict fencing of side effects unless each mutating RPC also validates the current lease inside its own transaction. This limitation must remain explicit until the pipeline is refactored to carry the lease tuple through every write boundary.
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


## Per-claim lease fencing (migration 008)

The replay worker must use the fenced RPC contract, not the generic job claim/completion functions:

1. Claim with `henvalt.claim_shopify_replay_job(worker_id, 180)`. The result includes `lease_id` and `lease_expires_at`. Lease duration is clamped to 30–900 seconds.

- For processing that may exceed the lease window, renew before expiry with `henvalt.renew_shopify_replay_lease(job_id, worker_id, lease_id, 180)`. It extends only the still-current lease and cannot revive an expired or superseded claim. If renewal returns NULL, stop processing and do not commit downstream effects.

2. Load the webhook with `henvalt.load_shopify_webhook_replay_job(job_id, worker_id, lease_id)`. The former two-argument loader is revoked from service_role; a worker-id-only claim is no longer sufficient.
3. Complete only with `henvalt.complete_shopify_replay_job(job_id, worker_id, lease_id)`.
4. Retry only with `henvalt.retry_shopify_replay_job(job_id, worker_id, lease_id, error, delay_seconds)`. The function caps delay at one hour and moves exhausted jobs to DEAD_LETTER.
5. If a lease expires, another worker may atomically reclaim the row and receives a new random lease_id. Every payload-load and state-transition operation from the old lease then fails. Do not attempt to reuse a previous lease ID.
6. Do not use `claim_next_job`, `complete_job`, `retry_job`, or `dead_letter_job` for `process_shopify_webhook` jobs. Those remain the existing contract for `execute_intervention` and are intentionally not changed by this migration.

Acceptance is in `tests/shopify-webhook-replay-lease-fencing-postgres-acceptance.sql`: it proves claim, payload load, forced expiry, atomic reclaim by a second worker, stale-worker load/complete/retry rejection, and successful completion by the current lease. CI applies migration 008 after the existing replay ingress migrations and runs this acceptance file against disposable PostgreSQL 17.


## Read-only active-workflow baseline — 2026-11-21

The following node contracts were re-read from the active n8n workflows before writing the replay patch specification. They are a baseline for a future isolated candidate graph, not permission to edit the published workflows.

### `HENVALT_RECOVERY` — active version `32e50bf7-4cbd-4070-bbba-f259ed17b369`

- `Claim Due Job` currently executes `SELECT * FROM henvalt.claim_next_job($1, ARRAY['execute_intervention']::text[])`.
- `Normalize & Guard` currently sets `has_job` only when both a job ID and `payload.intervention_id` exist. A Shopify replay job carrying `payload.webhook_id` is therefore rejected by the existing guard.
- `Job Claimed?` currently routes its true output directly to `Atomic Claim Intervention`; this intervention branch must remain unchanged.
- `Complete Job` and `Retry Job` call the generic job-control RPCs with job ID and worker ID. They must remain intervention-only.
- `Init Worker` feeds `Loop Interventions`; the loop returns to `Claim Due Job`. Add the replay claim into this scheduler cycle without creating a fourth workflow or routing replay jobs through the generic claim RPC.

### `HENVALT_INGEST` — active version `6368d539-708f-494a-8be8-b9601d0e8607`

- `Event Webhook` is POST `/henvalt/ingest`, `responseMode: onReceived`, with `rawBody: true`.
- `Verify Shopify HMAC` and `Resolve Shopify Tenant` are separate HTTP Request nodes; the latter has a 10-second timeout.
- `Supabase Ingest RPC` is a separate HTTP Request node with a 15-second timeout.
- `Classify Result` currently maps a generic HTTP 409 to HTTP 200 duplicate without requiring a durable webhook ID. This is unsafe for the candidate queue-ack contract; only the candidate classifier's explicit durable-ID/active-job rules may be used.
- No explicit Respond to Webhook node is present in the active ingress graph. The future isolated graph must use one explicit response path for every outcome and terminate the Shopify branch after durable queue acknowledgement.

### `HENVALT_DELIVERY` — active version `621ae6ce-a006-4fed-a70e-acf774c360fb`

- Both `MailerSend Send` and `MailerSend One-Off Test Email` remain present and call the same delivery Edge Function.
- Do not modify or publish this workflow as part of replay-worker wiring. The global no-send interlock and provider-egress-denied acceptance must be proven separately before any send path is enabled.

All three active workflow IDs, versions, and node counts were verified read-only. No active workflow or draft was changed during this inspection.


## Transactional business-write fencing (candidate migration 009)

Migration `202611210009_shopify_replay_business_write_fencing.sql` adds a service-role-only write guard and fenced entry points for the current Shopify mutating RPC families. Each wrapper:

1. Receives `job_id`, `worker_id`, and the exact `lease_id` issued by `claim_shopify_replay_job`.
2. Calls `assert_shopify_replay_lease_for_write` inside the same PostgreSQL transaction as the underlying business mutation.
3. The guard validates job type, CLAIMED status, worker, lease UUID, and unexpired lease using `clock_timestamp()`.
4. The guard selects the job row `FOR UPDATE`. That row lock remains held until the wrapper transaction commits or rolls back, so another worker cannot reclaim the job while the wrapped write is in flight—even if wall-clock lease expiry passes during that transaction.
5. A stale, expired, mismatched, or superseded lease raises SQLSTATE `42501` before the underlying mutation is invoked.

Candidate fenced entry points cover customer/consent/session identity, including `resolve_identity` because it creates or updates sessions and aliases, canonical event, checkout, opportunity, intervention enqueue, order projection, attribution, revenue adjustment, uninstall handling, and recovery-stop writes. The replay subflow must call these wrappers for every corresponding mutation; it must not call their unfenced counterparts from a Shopify replay job. The ordinary intervention scheduler and non-replay flows keep their existing RPC contract.

Acceptance test: `tests/shopify-replay-business-write-fencing-postgres-acceptance.sql` forces lease expiry and reclaim, proves the stale worker cannot insert a canonical event through the fenced RPC, then proves the current lease can. CI applies migration 009 only to disposable PostgreSQL 17 and runs that test.

**Scope limitation remains:** this is a fenced set of entry points, not proof that the entire replay subflow has been rewired. Before claiming end-to-end strict fencing, inventory every mutating node in the final replay subflow, map it to one of these wrappers (or add a wrapper for the missing RPC), and verify no legacy direct write remains. The live database remains on its earlier migration; migration 009 is candidate-only and has not been applied to production. No active n8n workflow was edited.


The current fenced RPC names are:
- `upsert_customer_fenced`
- `apply_shopify_email_consent_update_fenced`
- `bind_session_alias_fenced`
- `resolve_identity_fenced`
- `upsert_canonical_event_fenced`
- `upsert_checkout_fenced`
- `create_opportunity_idempotent_fenced`
- `create_intervention_and_enqueue_fenced`
- `project_order_from_event_fenced`
- `evaluate_order_attribution_fenced`
- `create_revenue_adjustment_fenced`
- `process_shopify_revenue_adjustment_fenced`
- `deactivate_shopify_connection_on_uninstall_fenced`
- `stop_recovery_after_order_fenced`
- `apply_eligibility_fenced`
- `create_recovery_sequence_fenced`
- `post_recovery_to_ledger_and_measure_billing_fenced`
- `defer_payment_webhook_reconciliation_fenced`

These names are the allowed mutation boundary for the replay path; any additional write RPC discovered in the final workflow graph must receive the same lease-checked wrapper before staging.

- `mark_webhook_processed_fenced`
- `mark_webhook_failed_fenced`

Webhook lifecycle state transitions are fenced too; the replay worker must not call the original unfenced status functions.


## Authoritative correction — transactional fencing supersedes heartbeat-only wording

This section is normative and supersedes any earlier wording in this document that suggests periodic lease renewal plus idempotency alone is sufficient to protect downstream writes.

- The replay worker MUST call the migration 009/010 `*_fenced` wrapper for every database mutation. A lease renewal before a stage is useful for early loss detection, but it is not a substitute for the wrapper's transaction-local lease check and `FOR UPDATE` lock.
- Never route a replay job through an unfenced mutation RPC, including the original webhook status functions.
- The exact allowed wrapper inventory is maintained in the final section of this document and in `docs/ACTIVE_WORKFLOW_CUTOVER_BLOCKERS_2026-11-21.md`. If a mutating RPC is not in that inventory, stop and add/test a fenced wrapper before staging.
- A worker that loses its lease must stop. Its subsequent fenced mutation, processed/failed marker, completion, and retry calls must all fail closed.
- The old numbered guidance in “HENVALT_INGEST replay entry” that describes heartbeat renewal as the primary protection is subordinate to this correction. Do not implement from that older paragraph without applying this authoritative correction.


## Complete active-ingest mutation inventory — audit correction

A read-only inspection of the live `HENVALT_INGEST` HTTP Request/Postgres node targets and the production `pg_proc` definitions found four additional mutation boundaries that were missing from migration 009's first wrapper inventory:

| Active node | Existing RPC | Candidate fenced RPC | Why it must be fenced |
|---|---|---|---|
| Apply Eligibility | `apply_eligibility` | `apply_eligibility_fenced` | Updates opportunity status. |
| Create Recovery Sequence | `create_recovery_sequence` | `create_recovery_sequence_fenced` | Inserts the recovery sequence and updates the opportunity. |
| Post Recovery To Ledger | `post_recovery_to_ledger_and_measure_billing` | `post_recovery_to_ledger_and_measure_billing_fenced` | Writes confirmed recovery revenue and billing measurement. |
| Defer Payment Reconciliation | `defer_payment_webhook_reconciliation` | `defer_payment_webhook_reconciliation_fenced` | Updates webhook state and deferred-reconciliation metadata. |

Candidate migration `202611210010_shopify_replay_complete_ingest_write_fencing.sql` adds these four wrappers. Its disposable PostgreSQL acceptance test forces lease replacement, proves each stale call is rejected before reaching the legacy RPC, then proves the current lease can call all four wrappers.

The following active-ingest RPCs were classified as read-only in the same inspection and do not require write wrappers: `evaluate_eligibility`, `score_recovery_intent`, `get_recovery_flow_delay`, and the payment-order lookup SELECT. This classification is based on the current live definitions and must be repeated against the final replay graph before staging.

This audit correction does not mean the active workflow has been rewired: the published workflow still calls its original RPCs. Migration 010 is candidate-only and is not applied to production.


## Recovery replay branch contract — candidate revision

A machine-readable scheduler contract now lives at `n8n/shopify-recovery-replay-branch-contract.json`, with static assertions in `tests/shopify-recovery-replay-branch-contract.test.mjs`.

The scheduler must attempt at most one job from each queue per cycle. The existing intervention claim remains restricted to `execute_intervention`; after every intervention terminal outcome it attempts one separately leased Shopify replay claim. If no intervention is available, it attempts the replay claim immediately. A replay terminal outcome returns to the scheduler loop. This prevents a continuously non-empty intervention queue from starving webhook replay while retaining the existing intervention business path.

The replay branch is a separate contract:
- Claim only through `claim_shopify_replay_job(worker_id, 180)`.
- Validate `job_id`, `worker_id`, `lease_id`, and `payload.webhook_id`; reject unknown job types.
- Load, complete, and retry only with the exact `job_id + worker_id + lease_id` tuple.
- Call the dedicated `HENVALT_INGEST` replay entry with only that tuple. The ingest subflow reloads the trusted stored payload and executes sequential transaction-local fenced writes from the audited write map.
- Complete only when the subflow confirms `mark_webhook_processed === true`; otherwise use bounded retry and allow the database RPC to dead-letter exhausted attempts.
- Never route replay work through `Atomic Claim Intervention` or the generic `complete_job` / `retry_job` functions.

This is a tested design contract, **not a constructed n8n graph**. It does not alter or publish the live workflow, and passing static CI does not establish that the n8n nodes have been wired. The exact active version remains the read-only baseline until a separate candidate graph can be authored and accepted in isolated staging.


### Exact replay-claim row normalization

The migration 008 implementation returns `SETOF henvalt.background_jobs`, so the raw claim row exposes `id`, not a `job_id` column. The candidate recovery normalizer must map `id → job_id`, carry the worker ID used for the claim, preserve `lease_id` byte-for-byte, retain `lease_expires_at`, and parse `payload.webhook_id` as a UUID. It must not assume the RPC returns a pre-normalized `job_id` or a `worker_id` field. This exact return-shape check is pinned to migration 008 in the recovery branch static test.


### Active mutation inventory and fenced-wrapper signature audit

The sanitized active-ingest snapshot now records all 18 observed mutating RPC nodes from version `6368d539-708f-494a-8be8-b9601d0e8607`. CI requires an exact one-to-one match between that inventory and the replay write map. It also parses every mapped SQL wrapper definition and verifies that the exact `job_id, worker_id, lease_id` arguments are first, and that the transaction-local lease guard executes before the wrapped legacy mutation (or the direct webhook status update). This is still static source validation; it does not prove the live workflow has been rewired.


## Recovery graph patch manifest — inspected topology correction

A candidate-only graph patch is now captured in `n8n/shopify-recovery-replay-graph-patch.json` and checked by `tests/shopify-recovery-replay-graph-patch-static.test.mjs`.

The read-only inspection found a second scheduler defect: only `Complete Job` and `Retry Job` currently return to `Loop Interventions`; `Retry Preflight Job`, `Retry Delivery Job`, and `Retry Pipeline Job` currently have no outgoing edge. The candidate patch connects all five intervention terminal outcomes to the replay claim, then returns the replay terminal path to the existing loop. It also connects the false output of `Job Claimed?` to replay claim and requires `alwaysOutputData` on both claim nodes so an empty result cannot silently bypass the other queue.

The replay claim RPC error stops the tick; a load failure may retry only with the exact lease tuple; completion/retry RPC errors and false results terminate fail-closed. The candidate does not add a fourth workflow or modify the delivery workflow.

The manifest is deliberately not an executable n8n export: the dedicated replay trigger and stored-payload replay entry still need to be built inside the existing `HENVALT_INGEST` candidate, and the combined three-workflow graph must be validated in isolated staging before any cutover.


A further graph-level guard now makes the replay payload reload emit an explicit empty item and checks the returned job/webhook/tenant/lease fields before branching. Empty or incomplete loads go to the lease-bound retry path; they cannot be interpreted as “already processed” and cannot reach the ingest subflow. This behavior is pinned by a separate static graph test.
