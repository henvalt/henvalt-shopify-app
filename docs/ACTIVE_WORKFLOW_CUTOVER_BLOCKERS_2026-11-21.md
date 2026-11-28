# Active n8n workflow cutover blockers — 2026-11-21

Status: read-only audit and candidate implementation contract. This file does not authorize or perform a live workflow update.

## Live versions inspected

| Workflow | ID | Active version | Critical finding |
|---|---|---|---|
| HENVALT_INGEST | VTpfGKNtu1CSQ4Rv | 6368d539-708f-494a-8be8-b9601d0e8607 | Shopify webhook uses `responseMode: onReceived`; processing continues after the immediate acknowledgement. |
| HENVALT_RECOVERY | 3GEDoeCA4paXTaDF | 32e50bf7-4cbd-4070-bbba-f259ed17b369 | `Normalize & Guard` requires `payload.intervention_id`; it cannot accept `process_shopify_webhook` replay jobs. |
| HENVALT_DELIVERY | CvVyybGJZSnklxiZ | 621ae6ce-a006-4fed-a70e-acf774c360fb | Ordinary send and manual one-off test send are separate outbound nodes; both call the same delivery Edge Function. |

## Cutover requirements — do not patch one node in isolation

### 1. HENVALT_INGEST: acknowledgement and single processing owner

The current immediate acknowledgement means later HMAC, tenant resolution, persistence, or projection failures cannot cause Shopify to retry. The replay design must make the ingress RPC the durable acceptance boundary.

Required graph behavior:

1. For Shopify requests, validate required transport headers and raw-body availability before invoking the atomic receive RPC.
2. Call the single-round-trip receive RPC that verifies HMAC over exact raw bytes, resolves the active tenant, and transactionally inserts the webhook plus replay job.
3. Return an explicit response from a Respond to Webhook node using the RPC's classified outcome. No path may silently default to 200.
4. After returning the response, Shopify events must terminate. They must not continue into the legacy inline projection path while the replay worker can claim the same event.
5. Keep any internal/non-Shopify path separate and preserve its existing authorization and tenant checks.
6. Ensure every branch returns exactly once. HMAC invalid => 401; verifier/config unavailable => 503; unknown shop => 404; invalid shape => 422; durable enqueue => 200.

Identity rule: the Shopify delivery ID is the replay idempotency key. Do not substitute `X-Shopify-Event-Id`, body `id`, or event correlation ID when the delivery ID is absent. Distinct delivery IDs must remain distinct even when their event correlation IDs match.

### 2. HENVALT_RECOVERY: preserve intervention work and add fenced replay work

The active guard currently assumes every claimed job has an intervention ID. The candidate patch must:

- Preserve the current `execute_intervention` claim and branch behavior.
- Claim `process_shopify_webhook` only through `claim_shopify_replay_job(worker_id, lease_seconds)`; never use the generic job claim for replay jobs.
- Validate replay payload UUIDs and reject unknown job types.
- Route by job type. The existing intervention branch must remain functionally unchanged.
- Pass the exact `job_id`, `worker_id`, and random `lease_id` to the replay subflow.
- Complete/retry/dead-letter replay jobs only through the lease-fenced RPCs and only with the same lease tuple.
- Treat an already-processed webhook as idempotent completion, without repeating projections or delivery enqueue.

### 3. HENVALT_INGEST replay subflow: fence every mutation

The earlier candidate worker note described heartbeat renewal before stages. That is insufficient by itself to prevent a stale worker from committing after lease loss. Migration 009's transaction-local fenced wrappers are the required write boundary.

For every mutation stage (identity/customer, canonical event, checkout/order, opportunity, intervention enqueue, attribution/ledger, webhook status):

- Call the corresponding `*_fenced` wrapper with job ID, worker ID, and lease ID.
- The wrapper must validate the current unexpired lease inside the same database transaction as the business write.
- Never call the unfenced equivalent from the replay path.
- Keep mutation stages sequential; no parallel fan-out of fenced writes.
- Renew the lease before long-running stages and stop immediately if renewal returns NULL.
- Mark the webhook processed only after every required stage succeeds. A stale worker must be unable to mark processed, retry, or dead-letter a job after lease replacement.

The worker spec's older statement that stage calls are merely idempotent plus periodic heartbeat is not an acceptable substitute for the transaction-local wrappers. The exact wrapper list and arguments must be checked against the migration definitions before workflow nodes are authored.

### 4. HENVALT_DELIVERY: default-deny provider boundary

The active workflow has two provider request nodes: the standard send node and a separate manual one-off test-send node. A workflow-only stop is not authoritative.

- The candidate database credential-release wrapper must be deployed and integration-tested in isolated staging before either route can be considered protected.
- The one-off test route must remain denied; do not enable it as a shortcut for testing.
- Staging tests must prove the actual credential-release RPC returns no token while the interlock is closed, including missing-control and simulated permission/read-failure cases.
- The provider HTTP boundary must use a network-denied stub for all positive-path authorization tests.
- Do not open the interlock for staging acceptance. Default stays NO SEND.

## Required automated workflow graph assertions

Add a workflow-contract test fixture (exported JSON snapshots, not live n8n API writes) that asserts:

1. Exactly these three workflow identities are present; no fourth workflow is introduced.
2. The published production version IDs above are not changed by candidate work.
3. Shopify ingress is configured for explicit response handling, not `onReceived`.
4. Every Shopify ingress outcome reaches exactly one explicit response node.
5. Shopify ingress does not connect to legacy inline mutation nodes after durable enqueue.
6. Replay claim uses the lease-producing RPC and carries the exact lease tuple through load, every fenced write, and terminal state transition.
7. No unfenced business mutation RPC is reachable from the replay branch.
8. Existing intervention claim and delivery scheduling branches remain connected.
9. Every provider HTTP request node is downstream of the final credential-release authorization; the manual one-off route cannot bypass the default-deny interlock.
10. No workflow node contains a literal recipient, customer payload, provider token, or real test message fixture.

## Staging acceptance order

1. Confirm a separate isolated Supabase project exists and has no production data dependency. Do not restore a paused project or create a branch/project until cost is known and the owner has explicitly accepted it.
2. Apply candidate migrations only to that isolated project, after schema compatibility and migration checksums are reviewed.
3. Import candidate workflow JSON into an isolated n8n draft or test instance. Do not update or publish the three active workflows.
4. Run graph-contract tests and database acceptance tests with synthetic tenants and network-denied provider stubs.
5. Run Shopify webhook replay tests: duplicate delivery, distinct delivery IDs, HMAC rejection, unknown shop, lease expiry/reclaim, stale-worker write rejection, retry, dead-letter, and processed-event replay.
6. Run a complete synthetic event-to-ledger path with provider sending disabled.
7. Separately verify execution-data retention and redaction settings using instance-owner evidence. Historical execution payloads demonstrate that workflow-level assumptions are insufficient.
8. Require a written go/no-go review before any production cutover. No release is implied by green candidate CI.

## Release state

**NO-GO for production launch.** Candidate SQL/CI success does not prove the active n8n versions implement the replay and fencing contract, does not prove the real production credential-release functions are interlocked, and does not provide a complete staging end-to-end result. Production, active n8n versions, Shopify release state, and provider sending must remain unchanged until the separate staging acceptance and explicit release decision are complete.


## Additional active-ingest write-boundary audit — 2026-11-21

A read-only node/RPC and `pg_proc` audit found that the first candidate fencing inventory did not include four mutations present in the live `HENVALT_INGEST` graph:

- `apply_eligibility` updates opportunity status.
- `create_recovery_sequence` inserts a recovery sequence and updates its opportunity.
- `post_recovery_to_ledger_and_measure_billing` writes revenue-ledger and billing-measurement state.
- `defer_payment_webhook_reconciliation` updates webhook processing state and deferred-reconciliation metadata.

Candidate migration `202611210010_shopify_replay_complete_ingest_write_fencing.sql` now adds transaction-local lease-checked wrappers for all four. The new disposable acceptance test must prove stale-lease rejection before legacy function invocation and successful calls under the current lease. Static coverage requires all four wrappers to remain in the replay contract.

Read-only functions observed in the same graph include `evaluate_eligibility`, `score_recovery_intent`, and `get_recovery_flow_delay`; these were not classified as writes. The final replay graph must still be re-audited node by node before staging.

**Release state remains NO-GO.** The active workflow continues to call its original unfenced RPC names. Migration 010 and the new acceptance test are candidate-only; no production migration or n8n workflow was changed.


## Replay-entry contract audit — 2026-11-21

A further read-only inspection of the active `HENVALT_INGEST` graph and candidate migrations corrected the replay-entry design against the exact SQL return contracts:

- Migration 008 replaces the earlier two-argument loader with `load_shopify_webhook_replay_job(job_id, worker_id, lease_id)`; the two-argument signature is revoked from `service_role`. The replay subflow must preserve the lease ID from the recovery claim row and pass all three values.
- The loader returns the stored tenant ID, webhook ID, delivery ID, topic, payload, ingress metadata, processing state, correlation ID, and lease expiry. It does not return the lease ID.
- The stored delivery ID is the webhook's source event ID. Replay normalization must set the canonical event ID from that delivery ID, not from the Shopify event-correlation header or payload entity ID.
- The active tenant lookup must still run, and the resolved tenant must equal the tenant ID returned by the lease-fenced loader before any replay mutation.
- The replay path can bypass a second HMAC call only after the trusted loader verifies the stored ingress HMAC attestation. Public Shopify ingress must use the atomic `receive_shopify_webhook_v1` RPC.
- A successful HTTP 200 for new/in-flight ingress requires both a durable webhook UUID and an active replay-job UUID/state. A legacy HTTP 409, missing ID, unknown result, or terminal queue state is not an accepted duplicate.
- The candidate replay graph now defines `deferred_payment_handoff=true` as a second completion outcome only after `defer_payment_webhook_reconciliation_fenced` returns true. This is a candidate contract, not live runtime proof; isolated staging must verify the RPC response, durable follow-up ownership, and replay-job completion together. The active workflow remains unchanged.

Candidate-only helpers and checks now exist:
- `n8n/shopify-ingest-replay-envelope-candidate.mjs` and `tests/shopify-ingest-replay-envelope.test.mjs`.
- `n8n/shopify-ingest-ack-classifier-candidate.mjs` and `tests/shopify-ingest-ack-classifier-candidate.test.mjs`.
- `n8n/shopify-ingest-replay-entry-candidate.json` and `tests/shopify-ingest-replay-entry-static.test.mjs`.
- Full design notes: `docs/N8N_SHOPIFY_INGEST_REPLAY_ENTRY_CANDIDATE.md`.

These are specifications and pure helpers, not a constructed/importable n8n graph. No active workflow was edited or published, no production database changed, and no provider send was enabled. **Release remains NO-GO pending the complete isolated graph, deferred-payment resolution, and staging acceptance.**


## Recovery preview-data sanitization — 2026-11-21

A read-only inspection of the active `HENVALT_RECOVERY` export found that the manual one-off email preview response includes a literal recipient value. The node is a preview path and is not itself a provider-send node, but the value is still personal data. Any public sanitized workflow fixture, generated candidate export, CI artifact, or isolated draft must redact that literal and must not treat it as a real merchant/customer destination. This does not authorize changing the active workflow; production execution-data retention and redaction remain separate owner-level blockers.
