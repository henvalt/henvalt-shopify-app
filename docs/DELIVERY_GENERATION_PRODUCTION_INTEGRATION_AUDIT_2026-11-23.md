# Delivery-generation production integration audit — 2026-11-23

Status: **read-only production audit + candidate integration specification**. This document does not implement or authorize a production cutover. No production schema, Edge Function, n8n workflow, provider credential, or email was changed.

## Executive finding

The isolated delivery-generation model is sound as a reference contract, but it is not yet a deployable change. A second delivery request per intervention is blocked by a live unique index, and several live functions acquire lifecycle locks in an order that conflicts with the model's required parent-first serialization. The active one-off test path also resets a failed request in place, bypassing immutable generations. Finally, the provider egress boundary is only process-local; the database has no durable marker immediately before the MailerSend request.

These are concrete production integration blockers. The existing 42 PostgreSQL model cases and six concurrency races validate the isolated model only; they do not validate these live functions or the active n8n graph.

## Evidence captured

### Active n8n delivery workflow

Read-only inspection of workflow `CvVyybGJZSnklxiZ` returned:

- Name: `HENVALT_DELIVERY`
- Active: `true`
- Active/current version: `621ae6ce-a006-4fed-a70e-acf774c360fb`
- Node count: 62

The sanitized topology is pinned in `tests/fixtures/n8n-delivery-generation-contract-snapshot.json`.

Three relevant routes exist:

1. **Normal delivery:** `Authorize & Context` → `MailerSend Send` (Edge Function) → `Classify Result` → `Record Delivery Result` (`record_delivery_result`).
2. **MailerSend webhook:** signature verification → `process_mailersend_webhook_event`.
3. **Manual one-off test:** `Prepare One-Off Test Delivery` (`reauthorize_one_off_test_delivery`) → same Edge Function → one-off classifier → a second direct `record_delivery_result` call.

There are therefore two direct n8n callers of `record_delivery_result`, plus the SQL webhook processor. A cutover that updates only the ordinary send path is incomplete.

### Live database constraints

Read-only catalog inspection of the active Supabase project found:

- `ux_delivery_request_intervention` is a unique index on `(tenant_id, intervention_id)`. This makes multiple immutable delivery requests for one intervention impossible today.
- `delivery_requests_tenant_id_idempotency_key_key` is unique on `(tenant_id, idempotency_key)`; generation-specific idempotency keys must remain unique.
- `delivery_attempts_delivery_request_id_attempt_number_key` is unique on `(delivery_request_id, attempt_number)`.
- `provider_events_provider_hash_key` is unique on `(provider, event_hash)`.
- The production schema does not currently contain the candidate `email_usage_reservations` and `email_usage_reservation_events` tables from migration `202611230001_email_usage_reservations.sql`; that migration is candidate-only.

### Lock-order findings

The live functions do not yet share one lifecycle lock order:

| Function/path | Current lock behavior | Required integration |
|---|---|---|
| `create_delivery_request` | Locks `recovery_interventions` before looking up/creating `delivery_requests` | Already parent-first; preserve |
| `authorize_delivery_request` | Locks `delivery_requests`, then reads the intervention without locking it | Lock intervention first, then request; recheck current generation |
| `record_delivery_result` | Locks request first, then locks intervention | Reverse to intervention → request |
| `get_mailersend_token_for_delivery` | Updates/claims request directly; no parent lock | Lock intervention → request before claim; require current generation |
| `process_mailersend_webhook_event` | Locks request by provider message ID, then calls `record_delivery_result` | Resolve parent without locking request; lock parent → request; then settle |
| one-off reauthorization | Locks request, mutates tenant settings, then updates intervention | Remove the reset path; no request may be reset in place |

The important deadlock is not theoretical: a retry transaction must lock the intervention before inspecting and creating a generation. The current result RPC locks the delivery request first and then the intervention. Concurrent execution can therefore form the classic cycle: retry holds parent and waits for request; result settlement holds request and waits for parent. The webhook processor currently pre-locks the request before calling the result RPC, so fixing only `record_delivery_result` would not fix the webhook route.

The preferred global order for delivery lifecycle writes is:

1. `recovery_interventions` parent row;
2. `delivery_requests` generation row;
3. billing entitlement/account row when a claim changes `PENDING → UNKNOWN`;
4. quota reservation row;
5. attempt / provider-evidence rows.

The provider webhook may insert its idempotent receipt row first, but it must not lock a delivery request before the parent. It must resolve the parent using a non-locking lookup, acquire the parent lock, then lock the request and perform the state transition.

## Critical one-off bypass

The live `reauthorize_one_off_test_delivery` function is not merely a special authorization check. Its current body:

- verifies a hard-coded request, tenant, opportunity and recipient;
- requires a prior failed attempt with `tenant_provider_credential_unavailable` and HTTP 409;
- changes the same request from `FAILED` back to `PENDING`;
- clears `provider_claimed_at`;
- changes the intervention back to `SENDING`;
- temporarily turns tenant recovery settings on to call `authorize_delivery_request`, then restores them.

This violates the immutable-request rule and bypasses a generation counter. The active manual workflow still reaches the shared provider Edge Function after this RPC returns `can_send=true`. The generation cutover must replace this RPC with a fail-closed response (or a separately audited generation-aware test command); it must not retain the in-place reset behavior.

## Provider egress gap

The current Edge Function handler performs these steps:

1. validates request shape;
2. calls `get_mailersend_token_for_delivery`, which claims the request and returns the secret;
3. calls `assert_mailersend_delivery_envelope`;
4. sets a local JavaScript boolean `providerEgressStarted = true`;
5. calls `POST https://api.mailersend.com/v1/email`.

The local boolean controls whether an error response is labelled `pre_provider` or ambiguous, but it is not durable. A process crash cannot be distinguished from a provider call that began. The handler needs a service-role-only, compare-and-set RPC after envelope authorization and immediately before the provider HTTP request. That RPC must lock parent → request, prove the request is still the current generation, check the parent is not frozen, and write a one-way `provider_egress_started_at` marker. If the process crashes after the marker but before the network call, the generation must remain ambiguous and non-retryable by design.

Credential release currently happens before envelope authorization. This is acceptable only if the request remains non-retryable while the request is in `UNKNOWN`; a new generation must never be created from a token-claimed request without trusted pre-provider failure evidence and a released reservation.

## Late acceptance is a separate settlement path

The existing `record_delivery_result` correctly rejects transitions out of terminal `FAILED` and `REJECTED` states. Do not weaken that state machine to make late acceptance appear to work.

The current webhook processor resolves by `tenant:` tag plus provider message ID. It does not use the existing `delivery:` tag to resolve a request whose pre-provider failure occurred before a provider message ID was returned. A generation-aware webhook processor must:

- require exactly one well-formed `tenant:<uuid>` and exactly one `delivery:<uuid>` tag for this late-evidence path;
- verify request tenant, provider, immutable recipient and any already-bound provider message ID;
- deduplicate the event using the existing provider/event hash;
- lock parent → request;
- atomically consume a previously RELEASED reservation without rewriting the original `FAILED` request or deleting the original RELEASED event;
- append a contradiction/late-acceptance incident and freeze the intervention if a later generation exists or the request was marked pre-provider-failed;
- ensure any newer generation cannot claim or cross the egress fence after the parent is frozen.

Recipient-only matching is not acceptable. Missing or malformed delivery tags, tenant mismatch, recipient mismatch, conflicting provider message IDs, or event identity reuse must fail closed and roll back settlement side effects.

## Candidate schema and RPC shape

The production-shaped migration should be split into independently reviewable units, not one large untested rewrite:

1. Add `generation_number` (backfilled to 1), `provider_egress_started_at`, and trusted pre-provider failure metadata to `delivery_requests`; add parent freeze/incident fields to `recovery_interventions`.
2. Replace `ux_delivery_request_intervention` with unique `(tenant_id, intervention_id, generation_number)`. Keep the tenant/idempotency-key unique constraint.
3. Add an append-only retry-command ledger unique on `(tenant_id, intervention_id, retry_command_id)`; retries with the same command key return the same request.
4. Add a service-role-only generation-creation RPC. It locks parent → latest request → reservation; permits N+1 only after a server-authored pre-provider failure, a RELEASED reservation with the exact trusted reason, no egress marker, no accepted/ambiguous attempt, no unresolved provider evidence, and no parent freeze. It copies the immutable message/recipient envelope into a new request and uses `deliver:<intervention_id>:g<N>`.
5. Add a one-way egress-start RPC and a late-acceptance settlement RPC. Neither may accept caller-supplied claims as proof; both must derive tenant/intervention/request bindings from persisted rows.
6. Update `authorize_delivery_request`, `get_mailersend_token_for_delivery`, `record_delivery_result`, and `process_mailersend_webhook_event` to use the same parent-first order and current-generation fence.
7. Replace `reauthorize_one_off_test_delivery` with a fail-closed legacy response. Update the candidate n8n builder so the manual test path cannot reach the provider Edge Function through the old reset route.
8. Update the Edge Function handler to call the durable egress-start RPC after envelope authorization and before the provider HTTP call. The server-owned pre-provider marker must only be emitted when that RPC has not succeeded and the provider call has not begun.

The current recovery worker still needs an explicit retry-generation branch. Do not change its one-idempotency-key-per-intervention behavior by merely changing a string in n8n. It must call the idempotent database retry-command RPC and pass the returned new request identity through the same authorization, envelope, egress and result path.

## Required acceptance matrix before any deployment

### Database / concurrency
- Existing rows backfill to generation 1 without changing IDs, statuses, attempts, reservations or idempotency keys.
- Multiple generations can coexist for one intervention; duplicate generation and retry-command keys are rejected/idempotent as specified.
- Two distinct retry commands racing create exactly one next generation.
- Same retry command racing returns the same generation/request.
- Retry racing normal result settlement, webhook settlement, token claim, and egress marker cannot deadlock or create a second current generation.
- Stale generation cannot authorize, claim a provider token, or mark egress.
- A retry is denied for missing reservation, non-RELEASED reservation, wrong release reason, provider response, 409/429/5xx ambiguity, existing egress marker, accepted evidence, or any parent freeze.
- Late acceptance before retry creation prevents retry; late acceptance after retry creation freezes the parent before new claim/egress.
- Late acceptance after egress has begun consumes/holds quota conservatively and blocks all subsequent sends without pretending the in-flight provider request can be recalled.
- Every rejected evidence correlation rolls back the event receipt and all settlement side effects.
- Existing provider rejection allowlist, quota settlement monotonicity, and append-only reservation events remain unchanged.

### Active workflow and Edge Function
- Both direct n8n result callers use the same generation-aware result contract.
- The MailerSend webhook route no longer locks request before parent.
- The one-off legacy route is blocked before the shared provider Edge Function; no hard-coded test recipient can be sent.
- Network-denied provider stub proves zero MailerSend calls if the interlock is closed, token claim is denied, envelope is denied, generation is stale/frozen, or egress marker is rejected.
- A successful egress marker is committed before the provider stub is invoked.
- Crash simulation after egress marker is ambiguous and cannot be retried.
- Unsubscribe, hard bounce, soft bounce, spam complaint, inbound reply, click tracking, and privacy routes retain their current semantics.

### Release boundary
- First run the migration against a disposable PostgreSQL 17 database with a production-shaped schema and every function/trigger dependency.
- Then run isolated Supabase staging with the complete schema, roles, Vault, Edge Functions and candidate n8n exports.
- Run both normal and manual route egress-denial tests using network-denied provider stubs.
- Review SQL lock graphs and deadlock logs under concurrent retry/claim/webhook load.
- Only after all evidence passes should a separately reviewed cutover be proposed. Production remains untouched until explicit approval.

## Service-role reachability

A read-only privilege check confirmed that `service_role` can execute all four relevant RPCs: `reauthorize_one_off_test_delivery`, `get_mailersend_token_for_delivery`, `record_delivery_result`, and `process_mailersend_webhook_event`. These are not dead catalog objects or inaccessible legacy routines; the active server-side integration role can reach them. The token-release function also contains a hard-coded one-off test allowlist branch. This makes the one-off reset path an actual reachable cutover concern, not just historical code.


## Production-shaped migration candidate — 2026-11-23

A first additive production-shaped migration candidate is now present at `supabase/migrations/202611230002_delivery_generation_schema_and_retry_rpc.sql`. It depends on the preceding candidate quota-reservation migration and deliberately does **not** rewrite the active authorization, provider-token, result-settlement, or webhook RPCs.

The candidate migration currently implements:

- Existing delivery requests backfill to generation 1 without changing request IDs or statuses.
- The one-request-per-intervention unique index is replaced by tenant/intervention/generation uniqueness.
- One retry-command ledger row per command, plus an append-only incident ledger.
- Monotonicity triggers prevent generation-number mutation, egress-marker rollback, parent-freeze rollback, and retry/incident ledger edits.
- `create_delivery_retry_generation` locks the parent intervention before the previous generation and quota reservation; it requires a FAILED parent/request, server-authored `pre_provider` evidence, a RELEASED quota hold tied to the exact latest attempt and an append-only RELEASED event, no egress marker, and no provider event for the prior request.
- The retry command is idempotent. A repeated command returns the same request.
- The new request copies the existing immutable message/recipient envelope, gets a generation-specific idempotency key, and remains PENDING. It does not pre-create a quota reservation: the existing entitlement trigger still reserves quota atomically at PENDING → UNKNOWN.
- A provider-token claim timestamp alone does not prohibit retry when the latest attempt is server-proven pre-provider and all other evidence is clean. The timestamp is not a durable provider-egress marker.

A separate production-shaped PostgreSQL 17 fixture and acceptance script now apply this migration against the live table/enum shape (without connecting to Supabase). CI verifies generation-1 backfill, immutable prior request, generation-2 creation, same-command idempotency, pending-generation fork denial, exact reservation release evidence, append-only behavior, and service-role-only RPC authorization.

### Explicit incompleteness

This migration is **not ready to deploy**. It does not yet:

- Reorder `authorize_delivery_request`, `get_mailersend_token_for_delivery`, `record_delivery_result`, or `process_mailersend_webhook_event` into the same parent-first lock order.
- Replace the legacy one-off reauthorization RPC or remove its hard-coded token-release exception.
- Add the durable compare-and-set provider-egress RPC and call it immediately before MailerSend HTTP egress.
- Rework late provider acceptance to resolve exact `tenant:` + `delivery:` tags and freeze newer generations.
- Wire the recovery worker to issue a retry command and carry the new request ID through the normal delivery route.

The migration is an executable first slice of the production-shaped implementation, not a completed delivery-generation cutover. It must not be applied to production or staging until the remaining RPC/Edge/n8n changes and complete concurrency suite are validated together.


### Production-shaped CI harness correction

The first production-shaped migration CI attempt reached the migration and failed at its role revocation statements because the disposable fixture had not created Supabase's `anon` and `authenticated` roles. This was a fixture defect, not a production database failure. The fixture now creates `anon`, `authenticated`, and `service_role` before applying the migration. The same run had already passed the existing 42-case reference-model suite and the new production-shaped schema bootstrap. A fresh exact-head run after the role correction is not yet confirmed; do not treat the migration candidate as passing until that run completes successfully.

## Current disposition

The six CI workflows for candidate `225ea379448a21270b0415863b7fc6152464caa2` passed, including the 42-case isolated PostgreSQL model and six concurrency races. Those results do not close the live integration blockers above. PR #7 remains draft and unmerged. No production migration, Edge Function deployment, n8n workflow mutation/execution, provider request, or email was performed.


## Durable provider-egress fence candidate — 2026-11-23

A second candidate migration, `202611230003_delivery_provider_egress_fence.sql`, now adds the missing database compare-and-set boundary. It depends on the generation schema/RPC migration and the global provider-send interlock candidate.

The service-role-only `mark_mailersend_provider_egress_started` RPC:
- resolves the intervention without locking the child request, then locks parent → request;
- requires the intervention to remain SENDING and unfrozen;
- requires a claimed UNKNOWN MailerSend EMAIL request;
- rejects stale generations whenever a newer generation exists;
- rechecks the global provider-send interlock;
- writes `provider_egress_started_at` once and refuses every second crossing.

The MailerSend Edge Function candidate now calls this RPC after the database envelope assertion and immediately before the provider HTTP request. If the fence RPC rejects, returns false, times out, or is unavailable, the handler returns a server-authored pre-provider rejection and does not call MailerSend. Once the fence succeeds, a crash or provider transport failure remains ambiguous and non-retryable.

The production-shaped PostgreSQL fixture now models the global interlock and tests closed-gate denial, one successful crossing, duplicate crossing rejection, and marker immutability. The Node handler tests assert the provider stub is unreachable unless the egress-fence RPC returns true.

**Important limitation:** this is candidate-only. The live Edge Function and live Supabase schema remain unchanged. The marker is a durable statement that the provider boundary was crossed; it cannot recall a request already in flight if the operator closes the interlock or a late-acceptance webhook arrives immediately after the marker commits. The existing lock-order rewrites, webhook late-acceptance settlement, legacy one-off removal, recovery-worker retry wiring, and isolated Supabase staging remain mandatory before cutover.


## Parent-first delivery lifecycle lock-order candidate — 2026-11-23

A fourth candidate migration, `202611230004_delivery_lifecycle_parent_first_lock_order.sql`, now addresses the deadlock inversion found in the read-only deployed RPC audit. The canonical order is:

1. `recovery_interventions` parent row
2. `delivery_requests` child row

The migration obtains each current deployed function definition using `pg_get_functiondef`, performs narrow, guarded source substitutions, and executes the resulting `CREATE OR REPLACE FUNCTION`. This preserves the existing validation and state-transition bodies rather than re-authoring the large production functions from partial excerpts.

The candidate patches all four entry points:
- `authorize_delivery_request`: locks the intervention before its request `FOR UPDATE`.
- `get_mailersend_token_for_delivery`: resolves the parent key without a child lock, locks the intervention, then performs the request claim update.
- `record_delivery_result`: reads the parent key without a row lock, locks the intervention, then performs the original request `FOR UPDATE`.
- `process_mailersend_webhook_event`: removes its preliminary request `FOR UPDATE`; result settlement delegates to the parent-first result RPC.

A dedicated disposable PostgreSQL 17 workflow bootstraps the exact RPC signatures and lock-bearing source shapes, applies the guarded migration, checks the rewritten function definitions, and calls each function. This validates the migration mechanics and expected ordering on the fixture; it is not a substitute for applying it to a staging copy of the full deployed schema and exercising real concurrent n8n/webhook sessions.

**Remaining lock-order risk:** other callers or triggers may lock delivery requests or interventions outside these four functions. The two direct n8n `record_delivery_result` callers are compatible with the new parent-first result RPC once deployed, but their surrounding workflow transactions and the legacy one-off path still require separate review. The hard-coded one-off allowlist in the live token RPC is not removed by this migration. No production function, schema, Edge Function or n8n workflow was changed.


## Legacy one-off delivery shutdown candidate — 2026-11-23

Candidate migration `202611230005_disable_legacy_one_off_delivery.sql` closes a separate generation-integrity hole discovered in the deployed token and test RPCs.

The old `reauthorize_one_off_test_delivery` implementation could:
- lock a FAILED delivery request and reset it in place to PENDING;
- clear `provider_claimed_at`;
- change the parent intervention back to SENDING;
- temporarily turn tenant recovery and the abandoned-checkout flow on, call authorization, then restore settings.

The token RPC also contained a hard-coded tenant, opportunity, recipient, idempotency key and `test_only` message exception. The candidate migration removes that exception from the token RPC, replaces both `reauthorize_one_off_test_delivery` and `prepare_one_off_test_delivery` with fail-closed exceptions, and revokes their execute grants from PUBLIC, anon, authenticated and service_role.

A dedicated PostgreSQL acceptance script verifies that the normal tenant-scoped token claim remains functional, the hard-coded allowlist disappears, both legacy RPCs reject calls, and service_role no longer has execute permission.

This is a deliberate cutover blocker, not a production change. The active n8n manual one-off route must be removed or replaced with an isolated safe test workflow before this candidate migration is applied to any live environment. Production remains unchanged.
