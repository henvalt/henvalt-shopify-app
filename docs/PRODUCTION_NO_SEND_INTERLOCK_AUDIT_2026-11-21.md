# Production no-send interlock audit — 2026-11-21

## Scope and safety

Read-only inspection of the live Supabase project and the published n8n delivery workflow. No production rows, functions, secrets, workflow definitions, or provider settings were changed. No provider request or email was sent.

This document is a release blocker record and implementation contract, not authorization to deploy.

## Verified live findings

1. The published `HENVALT_DELIVERY` workflow is active (workflow ID `CvVyybGJZSnklxiZ`, active version `621ae6ce-a006-4fed-a70e-acf774c360fb`).
2. It has two distinct outbound provider call nodes:
   - `MailerSend Send` on the ordinary internal-delivery webhook path.
   - `MailerSend One-Off Test Email` on the manual-trigger path.
   Both call the `henvalt-mailersend-delivery` Edge Function.
3. The live `henvalt.get_mailersend_token_for_delivery(uuid, uuid)` SECURITY DEFINER function claims an eligible delivery and returns the MailerSend token. Its authorization predicate includes a hard-coded one-off exception tied to a single tenant, opportunity, recipient, idempotency key, and test-only message metadata.
4. That hard-coded exception is a special-case authorization bypass, not a global no-send interlock. The function has no global release/kill-switch predicate.
5. Live `henvalt.provider_configs` contains 2 rows, both active. This count is metadata only; no credential values were read.
6. Live `henvalt.delivery_requests` currently contains 2 ACCEPTED and 1 DELIVERED rows (from the read-only status aggregation). These are historical states, not evidence of a current send in progress.
7. No verified global no-send control was found in the live database function or published workflow graph.


## Fresh live credential-release recheck — 2026-11-23

The earlier statement that no global recovery gate existed in the live delivery path is now superseded by a fresh read-only inspection of the current deployed functions and active n8n workflow:

1. **Ordinary delivery authorization checks the live switches.** `henvalt.authorize_delivery_request` requires an ACTIVE tenant, matching PENDING request, SENDING intervention, active recovery sequence, eligible opportunity, current tenant setting `henvalt_app.recoveryEnabled=true`, and the matching per-flow `enabled=true`. It then rechecks Shopify connection, order conversion, consent/jurisdiction, suppression, message/unsubscribe, sender and provider configuration before changing the request to the pre-send UNKNOWN state.
2. **Credential release independently rechecks the switches.** `henvalt.get_mailersend_token_for_delivery` repeats the tenant/global/per-flow, consent, suppression, opportunity, connection, sender-domain and delivery-claim conditions in the final Vault-token release predicate. The ordinary route therefore has a second gate after `authorize_delivery_request`, protecting the gap between authorization and secret retrieval.
3. **A narrowly scoped manual test exception still bypasses the normal switch.** The live token-release function retains an exact one-off test exception tied to a single tenant, opportunity, delivery request, idempotency key and `test_only=true` message. The active `HENVALT_DELIVERY` workflow has a separate manual-trigger node that calls `reauthorize_one_off_test_delivery`; that function only accepts the specific failed test request after one credential-unavailable 409 attempt, then temporarily enables the recovery switch and checkout flow inside its transaction, runs the same authorization function, and restores the original settings before commit. This is not a general merchant-send bypass, but it can authorize a real test email to its hardcoded allowlisted recipient. **Do not execute this manual trigger without explicit user approval.**
4. **Current tenant state is closed and has no queued send work.** Read-only counts show the global recovery switch is false, all four flow toggles are false, zero queued/claimed `execute_intervention` jobs, zero READY/SCHEDULED/SENDING interventions, and zero PENDING/QUEUED/PROCESSING delivery requests. One historical recovery sequence remains ACTIVE, but it has no current intervention or delivery request. The recovery and delivery workflows themselves are active schedulers; their business send gates remain closed.
5. **No send or production mutation occurred during this recheck.** No workflow was executed, no provider token was released, no MailerSend request was made, and no email was sent.

### Updated interpretation

- The live ordinary delivery path already has tenant-level and per-flow checks at both authorization and credential release; the previous 21 November wording that these were wholly absent is stale.
- The remaining gap is that the special manual test exception can temporarily bypass the tenant switch. The candidate PR #7 provider interlock is still valuable because it places a single independent default-deny control above both ordinary and exceptional routes and removes reliance on a recipient-specific exception.
- Until that candidate is reviewed, staged and explicitly approved, keep the current recovery switch and all flow toggles OFF and do not run the manual test-send node. The candidate interlock is not live.


## Candidate implementation already present elsewhere

The open draft PR `#6` (`[DRAFT] HENVALT public-app hardening preparation`) already describes candidate work for a default-deny provider interlock, append-only operator audit, database trigger protection, and coverage of the ordinary and manual delivery paths. That candidate is not the live production implementation. This audit adds a fresh read-only verification of the current live credential-release function and records the exact production gap. Do not duplicate or fork the PR #6 implementation without reconciling its migration and tests first.

## Required interlock contract

The global stop must be enforced at the final credential-release boundary, not merely in the dashboard, n8n routing, or Edge Function UI.

- Default state is **NO SEND** when the control is absent, malformed, or unreadable.
- The credential-release RPC must check the global release state before claiming a delivery or reading a provider secret.
- Every exception path, including the legacy one-off test exception, must remain subordinate to the global stop.
- The Edge Function must fail closed if the RPC denies release or returns an unexpected shape.
- Both n8n outbound nodes must remain unable to send when the interlock is closed; manual execution is not an exemption.
- Opening the interlock requires an explicit release decision and a separately tested policy; it must not be the default.
- The stop must be independently verifiable using a non-secret read-only status surface and a controlled denial test that cannot reach the provider.

## Candidate implementation and acceptance requirements

1. Design a single authoritative global send-control record with a fail-closed default. Avoid a second, divergent control in n8n.
2. Amend the credential-release function so the control is checked before the delivery claim and before any Vault secret read. Remove the hard-coded one-off authorization exception; do not replace it with another recipient-specific exception.
3. Add PostgreSQL acceptance tests for:
   - control row absent => denied;
   - control disabled => denied;
   - control malformed/unreadable => denied;
   - ordinary eligible delivery with control disabled => denied and no provider credential returned;
   - legacy one-off delivery with control disabled => denied and no provider credential returned;
   - enabled state still requires every existing tenant, consent, suppression, opportunity, verified-domain, idempotency, and delivery-claim check;
   - non-service roles cannot read or mutate the control;
   - function execution grants remain least-privilege.
4. Add an Edge Function acceptance test proving denied authorization cannot call MailerSend.
5. Add a workflow graph test proving every provider-send node is downstream of the same authorization boundary and no manual route bypasses it.
6. Independently inspect the published workflow version after any approved cutover; a draft-only change is not sufficient.

## Release decision

**BLOCKED — do not enable sending.** The current production credential-release boundary has no global no-send interlock and contains a hard-coded one-off exception. Do not apply candidate migrations, deploy Edge Functions, publish n8n changes, or enable any send path until the interlock is implemented, independently tested, and explicitly approved.


## 21 November — candidate interlock code review (read-only)

The PR #7 candidate migration and acceptance SQL were inspected against the live credential-release RPC definitions. This review does not modify or deploy either system.

### Candidate strengths

- provider_send_control is initialized closed and provider_sending_is_enabled() uses COALESCE(..., false), so a missing singleton row evaluates to deny.
- The delivery_requests trigger rejects a send-claim transition while closed, including an insert already marked UNKNOWN and a first provider-claim timestamp.
- The candidate delivery Edge Function authenticates its service-role bearer before parsing the body and calls the database credential-release RPC before the MailerSend network request.
- The latest candidate migration now renames the legacy credential-release function to a private implementation, revokes service-role access to that legacy entry point, and installs a same-signature SECURITY DEFINER wrapper. The wrapper checks the global interlock before the legacy code can claim the delivery or read Vault.
- The disposable PostgreSQL fixture now exercises the wrapper closed, enabled, and with the singleton row missing. A sequence-based secret-read sentinel proves the closed/missing-control paths do not reach the synthetic Vault read.
- The wrapper permanently rejects messages marked `test_only=true`, even when normal recovery sending is explicitly enabled. The fixture verifies the legacy one-off route cannot reach the synthetic Vault read while the normal eligible test path can.
- The gate assertion now takes a transaction-scoped `FOR SHARE` lock on the singleton control row. The operator setter takes `FOR UPDATE`, so closing the gate waits for already-authorized credential-release transactions to finish; later claims observe the closed state. The acceptance suite asserts this locking contract is present.
- The candidate staging document correctly notes that a database gate cannot revoke a credential already released to an in-flight request.

### Remaining candidate gaps — staging sign-off blocked

1. **The SQL acceptance file does not exercise the real send RPCs.** tests/provider-send-interlock-postgres-acceptance.sql checks synthetic inserts/updates against the trigger, but contains no invocation of authorize_delivery_request, reauthorize_one_off_test_delivery, or get_mailersend_token_for_delivery. It therefore does not yet prove that the ordinary and legacy one-off paths are denied end-to-end by the candidate migration against the real schema/function definitions.
2. **The legacy one-off exception remains in the live credential-release function source.** The candidate migration adds a database trigger that should stop the current one-off path when it attempts to claim the delivery, but it does not replace/remove the hard-coded exception in get_mailersend_token_for_delivery. Keep it explicitly subordinate to the global gate and remove it as a separate reviewed cleanup; never enable the global gate merely to exercise that route.
3. **Non-secret status surface and append-only audit are now implemented in the latest candidate.** Migration 001 adds provider_sending_status(), grants read-only execution to service_role only, and enforces append-only audit events with a database trigger rejecting UPDATE/DELETE. The acceptance test verifies the closed/missing-row status and immutable audit behavior. These remain candidate-only and are not live.
4. **Actual credential-release RPC integration coverage remains incomplete.** The SQL fixture still does not invoke the full production authorize_delivery_request, reauthorize_one_off_test_delivery, or get_mailersend_token_for_delivery definitions. The trigger is positioned on the exact delivery_requests claim transitions used by those paths, but staging must prove the real function definitions deny before Vault credential retrieval and that neither ordinary nor manual one-off route can return a token.
5. **Malformed/unreadable control-state behavior is not fully exercised at the actual credential-release boundary.** The missing-row status is tested and the gate uses a fail-closed COALESCE, but a simulated read/permission failure through the real credential-release RPC remains required.

### Required next candidate work

- Add disposable full-schema integration coverage that invokes the actual ordinary authorization, one-off reauthorization, and credential-release functions with the interlock closed; assert no provider token is returned and no provider HTTP call occurs.
- Add a least-privilege, non-secret status surface and test that application roles can read status but cannot mutate control state.
- Enforce append-only audit events if retained as the stated audit contract.
- Add missing-row and simulated read-failure tests at the final credential-release boundary.
- Re-run all checks on the exact resulting commit SHA. Do not infer production protection from the trigger-only fixture.

These are candidate-code review findings, not evidence of a production change. Production remains unchanged and send-capable until an explicitly approved, independently verified cutover is completed.


## 21 November — replay-worker lease review (read-only)

A further read-only comparison of the candidate replay-loader migration with the live job-control RPCs found a worker-recovery gap that must be resolved before the replay path is staged.

- The candidate loader (migration 006) requires job type process_shopify_webhook, status CLAIMED, and an exact locked_by worker ID. It does not check a lease token or an expiry timestamp.
- The live claim_next_job(p_worker_id, p_job_types) claims only QUEUED and RETRY_WAIT rows. It does not reclaim CLAIMED rows whose locked_at is stale.
- The live complete_job, retry_job, and dead_letter_job functions check status and locked_by, but do not check that the worker's lease is still current. A crashed worker can therefore leave a job permanently CLAIMED; a late worker with the same worker ID is not fenced by a per-claim lease generation.
- The candidate replay specification describes bounded retries and stale-worker rejection, but the current SQL loader plus generic job-control RPCs do not yet implement those guarantees.

Required candidate correction: add a bounded claim lease with a fresh per-claim lease identifier (or equivalent non-reusable fencing token), reclaim expired claims atomically, and require the same current lease identifier for payload loading, completion, retry, and dead-letter operations. Add concurrent PostgreSQL tests proving that an expired worker cannot load or finish after another worker reclaims the job, and that a crashed worker's job becomes claimable without manual row edits. Keep the existing execute_intervention path behavior unchanged while adding the new job type.

This is a candidate integration blocker. No live workflow or database object was changed.


## 21 November — replay lease terminal-state and renewal review

The candidate lease implementation was extended after review identified that a replay job expiring on its final permitted attempt would otherwise remain CLAIMED and never qualify for another claim.

- The claim RPC now atomically moves expired CLAIMED replay jobs with attempts >= max_attempts to DEAD_LETTER, clears lock/lease fields, and records the terminal reason.
- The acceptance SQL now covers this final-attempt expiry case in addition to lease issuance, renewal, reclaim, and stale-worker fencing.
- The worker specification requires lease renewal before expiry for long-running work and requires the worker to stop before committing downstream effects if renewal returns NULL.
- CI coverage is configured, but the updated test has not yet been observed passing on the resulting branch head.

Legacy CLAIMED replay rows with a NULL lease expiry are deliberately not auto-recovered by this change: they predate the lease contract and require a separately reviewed, age-bounded reconciliation policy. Do not silently reset them as part of the claim path.

The exact candidate head `3b7e931b0341d2eba42e99fedfce8c1a5e440b07` passed the HENVALT safety workflow on run [44887721007](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44887721007), including application of migration 008 to disposable PostgreSQL 17 and execution of the lease expiry/stale-worker acceptance test. Shopify configuration static validation passed on run [44887721070](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44887721070); its deployment job was skipped. These results validate the candidate fixture only, not production or isolated Supabase staging.

## 21 November — candidate replay lease-fencing implementation

A candidate-only implementation has now been added in migration `202611210008_shopify_replay_lease_fencing.sql` with PostgreSQL acceptance coverage in `tests/shopify-webhook-replay-lease-fencing-postgres-acceptance.sql`.

- Shopify replay jobs receive a fresh random `lease_id` and bounded `lease_expires_at` on claim.
- Expired claimed replay jobs are atomically reclaimable with a new lease ID.
- The old worker-ID-only replay loader is revoked from `service_role`; payload loading now requires the current unexpired lease.
- Dedicated completion and retry RPCs require the current lease. Retry delay is bounded and exhausted attempts transition to DEAD_LETTER.
- The existing generic job claim/completion contract remains unchanged for `execute_intervention`; the recovery design now separates generic intervention claims from fenced replay claims.
- CI workflow was updated to apply migration 008 and run the new stale-worker acceptance test on disposable PostgreSQL.

This is candidate code only. It has not been applied to Supabase production, and the active n8n recovery workflow has not been modified. CI results for the final commit must be checked before treating the candidate as validated. Full isolated staging, n8n wiring, and end-to-end delivery/attribution acceptance remain outstanding.


## 21 November — replay subflow lease-token contract correction

A cross-document review found the HENVALT_INGEST replay-entry section still described the revoked two-argument loader, despite the recovery branch and migration 008 requiring a per-claim lease token. The candidate worker specification now passes `job_id`, `worker_id`, and the exact `lease_id` into the ingest subflow; its second payload load, renewals, completion and retry all use that same lease. A static regression test now guards the contract and the fail-closed renewal rule.

The exact candidate head `9dc247ff7aa78dad933b628edbd2e32257ea3f23` passed HENVALT safety run [44887910222](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44887910222). Verified successful steps include the Node static test suite, both Edge Function type checks, disposable PostgreSQL 17 bootstrap, all candidate migrations 001–008, replay enqueue/loader/ingress acceptance, lease fencing acceptance, and the existing interlock/consent/dashboard/token-refresh acceptance suite. Shopify configuration static validation passed on [44887910188](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44887910188); deployment was skipped.

This remains candidate CI only. The three active n8n workflows were re-read and remain on their original active versions; no workflow draft or active version was changed. The live ingress and recovery paths therefore remain unconverted, and isolated full-schema staging remains a release blocker.


## 21 November — production migration boundary recheck

A fresh read-only Supabase MCP inspection reconfirmed the connected project is `ACTIVE_HEALTHY` on PostgreSQL 17.6.1. Its latest applied migration remains `20261114174204` (`fix_mailersend_token_browse_case_expression`); candidate migrations `202611210001` through `202611210008` are not applied. The development-branch inventory is still empty. No migration, data write, branch creation, or deployment was performed during this check.


## 21 November — replay side-effect fencing limitation identified

A further design review distinguishes lease fencing at the queue boundary from strict fencing of downstream business writes. Migration 008 fences claim, payload load, renewal, retry and completion, but it does not inject the lease tuple into every existing canonical-event, customer/checkout, opportunity, intervention, attribution or ledger RPC. Therefore it cannot by itself guarantee that a worker whose lease expires during an in-flight downstream call is prevented from completing that call.

The candidate worker specification now requires a sequential heartbeat renewal before each potentially long-running or mutating stage, bounded per-stage timeouts, idempotency keyed by tenant plus source event/webhook, and immediate stop when renewal returns NULL. It explicitly does not claim strict cross-system side-effect fencing until mutating RPCs validate the lease inside their own transaction. A static regression test covers this boundary. This is a release blocker for claiming strong lease fencing, not something to hide behind the queue-level acceptance test.

The heartbeat-contract code/spec update is at candidate commit `51622178fef4ac299f608a040e7673b7f207930b`; exact-head CI has not yet been observed for this commit.
