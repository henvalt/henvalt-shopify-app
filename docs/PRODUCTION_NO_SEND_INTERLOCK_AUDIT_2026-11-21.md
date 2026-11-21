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
- The candidate staging document correctly notes that a database gate cannot revoke a credential already released to an in-flight request.

### Remaining candidate gaps — staging sign-off blocked

1. **The SQL acceptance file does not exercise the real send RPCs.** tests/provider-send-interlock-postgres-acceptance.sql checks synthetic inserts/updates against the trigger, but contains no invocation of authorize_delivery_request, reauthorize_one_off_test_delivery, or get_mailersend_token_for_delivery. It therefore does not yet prove that the ordinary and legacy one-off paths are denied end-to-end by the candidate migration against the real schema/function definitions.
2. **The legacy one-off exception remains in the live credential-release function source.** The candidate migration adds a database trigger that should stop the current one-off path when it attempts to claim the delivery, but it does not replace/remove the hard-coded exception in get_mailersend_token_for_delivery. Keep it explicitly subordinate to the global gate and remove it as a separate reviewed cleanup; never enable the global gate merely to exercise that route.
3. **No application-readable status surface is provided.** The candidate revokes execution of provider_sending_is_enabled() from service_role, authenticated, and anon, and provides no separate status view/RPC. The operator can inspect through privileged SQL, but the required independent non-secret status check is not yet implemented.
4. **The audit log is access-restricted but not database-enforced immutable.** The candidate revokes application-role access to provider_send_control_events, but does not add a trigger rejecting UPDATE/DELETE. If append-only integrity is a requirement, enforce it in the database and test it.
5. **Malformed/unreadable control-state behavior is not fully exercised.** The current acceptance SQL tests a missing row after deletion and a false state, but does not test an unavailable/permission-error read through the actual credential-release path. The fail-closed result must be proven at that boundary.

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

## 21 November — candidate replay lease-fencing implementation

A candidate-only implementation has now been added in migration `202611210008_shopify_replay_lease_fencing.sql` with PostgreSQL acceptance coverage in `tests/shopify-webhook-replay-lease-fencing-postgres-acceptance.sql`.

- Shopify replay jobs receive a fresh random `lease_id` and bounded `lease_expires_at` on claim.
- Expired claimed replay jobs are atomically reclaimable with a new lease ID.
- The old worker-ID-only replay loader is revoked from `service_role`; payload loading now requires the current unexpired lease.
- Dedicated completion and retry RPCs require the current lease. Retry delay is bounded and exhausted attempts transition to DEAD_LETTER.
- The existing generic job claim/completion contract remains unchanged for `execute_intervention`; the recovery design now separates generic intervention claims from fenced replay claims.
- CI workflow was updated to apply migration 008 and run the new stale-worker acceptance test on disposable PostgreSQL.

This is candidate code only. It has not been applied to Supabase production, and the active n8n recovery workflow has not been modified. CI results for the final commit must be checked before treating the candidate as validated. Full isolated staging, n8n wiring, and end-to-end delivery/attribution acceptance remain outstanding.
