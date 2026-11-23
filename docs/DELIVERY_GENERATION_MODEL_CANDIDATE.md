# Delivery-generation model — candidate design

Status: design and executable reference-model tests only. No schema migration, n8n workflow edit, Edge Function change, provider request, email, or production write is included.

## 1. Why generations are required

The current recovery path uses one delivery idempotency key per intervention:

`deliver:<intervention_id>`

The current `create_delivery_request` behavior returns the existing row for that tenant/key. The request is claimed once (`provider_claimed_at IS NULL`), and a claimed request is not safely reset to `PENDING`. This is correct for ambiguous provider outcomes, but it also means a server-proven pre-provider failure can be terminal and unretryable.

The retry identity must therefore change without mutating the identity or history of an earlier request.

## 2. Proposed identity model

A logical intervention is the stable parent. A delivery generation is an immutable child identity.

- Parent: `(tenant_id, intervention_id)`.
- Generation: positive, monotonically increasing integer, starting at 1.
- Request identity: a new immutable `delivery_request_id` for each generation.
- Idempotency identity: `deliver:<intervention_id>:g<generation>`.
- Retry command identity: a caller-supplied, durable idempotency key scoped to tenant + intervention; repeated command submissions return the same generation.
- Each request has exactly one generation. Attempts and provider events attach to that generation; they do not create generations.
- The generation number is never reused, decremented, or inferred from timestamps.

Candidate uniqueness constraints (names illustrative; exact DDL must follow the live schema audit):

1. Unique `(tenant_id, intervention_id, generation_number)`.
2. Unique `(tenant_id, idempotency_key)` for each immutable request.
3. Unique `(tenant_id, intervention_id, retry_command_key)` for retry command deduplication.
4. At most one current/claimable generation per intervention, enforced transactionally rather than by application-side check-then-insert.

A separate immutable generation table is preferred over overloading a single mutable delivery request row. If implementation instead adds columns to `delivery_requests`, it must preserve the same immutable parent/generation/request identity and constraints.

## 3. State and provider-egress boundary

The generation lifecycle is deliberately split into durable pre-egress and possible-egress phases:

| State | Meaning | Retry permission |
|---|---|---|
| `PENDING` | Generation exists; no provider claim | No new generation unless this generation is explicitly cancelled before claim under a separately audited rule |
| `CLAIMED_PRE_PROVIDER` | One-time database claim and quota reservation exist; provider request has not begun | No |
| `PRE_PROVIDER_FAILED` | Trusted server evidence proves the provider HTTP call was never started; terminal | Yes, by creating a new generation |
| `PROVIDER_IN_FLIGHT` | Durable egress-start marker committed before network call | No |
| `ACCEPTED` | Provider accepted; message ID recorded where available | No |
| `AMBIGUOUS` | Timeout, connection loss, missing response, 408/409/429/5xx or otherwise inconclusive outcome after egress may have begun | No; reconcile only |
| `REJECTED_BY_PROVIDER` | A response was received; quota settlement follows the narrow existing provider policy | No automatic new generation |
| `CANCELLED_BEFORE_CLAIM` | Explicitly cancelled before any claim or egress | A new generation may be allowed only by a separately defined command |

The egress-start marker must be committed before the HTTP request is invoked. A crash after that marker but before the network call is intentionally treated as ambiguous. This sacrifices some retry availability to avoid duplicate customer email.

A `PRE_PROVIDER_FAILED` transition is accepted only from the trusted server-side delivery handler and only while the durable egress-start marker is absent. n8n/browser-supplied JSON, HTTP status alone, provider response content, or an arbitrary operator assertion must not create this evidence. Provider responses must overwrite/ignore any provider-supplied field that resembles the internal stage marker.

## 4. Atomic generation creation

Generation creation must be one database transaction:

1. Authenticate the internal caller and derive tenant/shop/intervention from trusted persisted context.
2. Lock the parent intervention row (or a dedicated per-intervention generation-counter row) with `FOR UPDATE`.
3. Look up the retry-command key. If it already exists, return its original generation unchanged.
4. Lock/read the latest generation and all unresolved provider attempts/reservations for the parent.
5. Permit generation N+1 only when generation N is terminal `PRE_PROVIDER_FAILED`, its quota reservation is `RELEASED` with the trusted pre-provider reason, and there is no egress-start marker, accepted evidence, ambiguous outcome, unresolved attempt, or active generation.
6. Allocate `max(generation_number)+1` while holding the parent lock.
7. Insert immutable generation/request identity and retry-command mapping.
8. Commit and return the existing-or-new generation identity.

The transaction must fail closed on missing parent, tenant mismatch, nonterminal prior generation, missing release evidence, contradictory attempt history, or any unknown state. It must not repair history by resetting old request status, clearing `provider_claimed_at`, deleting attempts, or changing old idempotency keys.

## 5. Claim and egress fencing

Both the authorization/claim RPC and the provider-token claim/envelope authorization path must independently verify that the request belongs to the current generation for the intervention.

- Only the current generation can be claimed.
- A generation can be claimed once.
- Only one generation can be in a possible-egress state at a time.
- The provider egress-start transition is compare-and-set: expected state is `CLAIMED_PRE_PROVIDER`, current-generation identity must still match, tenant/intervention/request/generation must all match, and the claim lease must still be valid.
- The egress-start transition commits before the provider HTTP call.
- A stale worker or delayed n8n execution for generation N cannot claim/send generation N after N+1 exists.
- Consent, unsubscribe, suppression, tenant status, billing entitlement, sender identity, and the existing provider interlock are re-evaluated at the existing authorization boundaries. Generation creation never bypasses them.

A generation lock is not a substitute for the global provider-send interlock or the delivery-envelope check.

## 6. Reservation and billing semantics

Quota is reserved once per claimed generation/request, not once per intervention. A new generation can be created only after the prior generation has a definitive pre-provider failure and its reservation is released.

- `PRE_PROVIDER_FAILED`: release only with trusted no-egress proof.
- `ACCEPTED`: consume.
- `AMBIGUOUS`: retain/consume conservatively under the existing policy; never release because of age or a retry timer.
- Late acceptance after a prior release: atomically upgrade that generation's reservation from `RELEASED` to `CONSUMED`, append a `LATE_ACCEPTANCE`/consumption event, and preserve the original release event.
- Provider rejection: preserve the existing narrow provider-status allowlist and settlement rules; do not broaden it as part of generation work.
- Every measurement is unique to the delivery attempt/generation and must not double-count when webhook, API response, and reconciliation evidence race.

If acceptance evidence contradicts a recorded pre-provider failure, treat it as a safety incident: consume the earlier reservation, freeze further generations for the intervention, preserve all evidence, and require operator review. Never silently reinterpret the older generation as a normal retry.

## 7. Provider ambiguity and reconciliation

An ambiguous generation is not retryable. Reconciliation may resolve it, but a negative result is not enough unless the complete provider search window, domain, filters, pagination and retention are proven complete.

- Exactly one matching provider record: record provider identity/status and settle according to the existing accepted/rejected evidence policy.
- More than one matching record: duplicate-send incident; freeze the intervention; preserve all provider IDs.
- No match with incomplete pagination, rate limit, API failure, missing domain scope, or expired retention: remain ambiguous.
- No match with demonstrably complete retained evidence: still require a separately reviewed negative-evidence rule before any release/retry. This design does not grant that permission.
- A late provider webhook is idempotent by provider event identity and is serialized with reservation settlement and generation freeze.

No provider read scope, domain lookup permission, account setting, or paid plan is assumed by this model.

## 8. Idempotent recovery behavior

Recovery retries are not generation creation.

- Re-running the same recovery job or replaying the same n8n execution must resolve to the same current generation and request ID.
- Repeating the same retry command key must return the same new generation.
- A distinct retry command cannot create a second generation while one is current, pending, claimed, in-flight, accepted, ambiguous, or otherwise unresolved.
- A retry command may create N+1 only after the previous generation has a trusted terminal pre-provider failure and released reservation.
- Delayed workers carry generation + request IDs and are rejected if stale.
- A retry scheduler must never automatically convert `AMBIGUOUS` to a new generation.

## 9. Required acceptance matrix

The reference-model suite covers these twenty scenarios; database acceptance must later repeat the transactional cases with independent PostgreSQL sessions and the real candidate schema.

1. First generation is generation 1 with stable parent identity.
2. Duplicate retry-command key returns the same generation.
3. Two different retry commands racing cannot create two current generations.
4. A retry before prior terminal pre-provider failure is rejected.
5. A retry after trusted pre-provider failure creates exactly N+1.
6. A forged/untrusted pre-provider marker is rejected.
7. An egress-started generation cannot be retried.
8. A timeout after egress remains ambiguous and cannot be retried.
9. A provider 409/429/5xx remains ambiguous.
10. A provider acceptance consumes the generation reservation.
11. A late acceptance upgrades a released reservation and appends evidence.
12. Duplicate acceptance webhook is idempotent.
13. Late acceptance after N+1 creation freezes the parent and records an incident.
14. Multiple provider matches freeze the parent and preserve every ID.
15. Incomplete/no-match provider lookup leaves the generation ambiguous.
16. A stale generation worker cannot claim after N+1 exists.
17. A stale generation cannot cross the provider-egress fence.
18. Consent/interlock denial cannot be bypassed by a new generation.
19. Recovery replay without a new retry command does not increment generation.
20. Generation numbers and request identities are immutable and monotonic.

## 10. Implementation sequence after reference-model review

1. Read-only schema inventory of delivery requests, interventions, attempts, reservations, claim RPCs, token-release RPCs, and all callers.
2. Candidate SQL design for parent lock, generation identity, retry-command idempotency, and immutable history.
3. Disposable PostgreSQL acceptance with two-session races for duplicate retry commands, stale claims, generation allocation, and late acceptance.
4. Candidate n8n recovery/delivery graph builders updated to pass generation/request identity and reject stale generations.
5. Network-denied provider-stub integration proving zero provider calls on denied/stale paths.
6. Full candidate CI and review. Isolated Supabase staging remains a separate release prerequisite.

This document does not authorize production schema changes, Edge Function deployment, active n8n changes, Shopify release, provider credential/scope changes, or email sending.


## 11. Read-only live schema and RPC audit — 2026-11-23

A read-only catalog query against the connected production Supabase project confirmed the exact structural constraints. No rows, schema objects, functions, secrets, or settings were changed.

Observed `henvalt.delivery_requests` fields include `id`, `tenant_id`, `intervention_id`, `status`, `idempotency_key`, and `provider_claimed_at`. There is currently no `generation_number`, retry-command key, or durable provider-egress-start timestamp.

Observed indexes/constraints:

- `ux_delivery_request_intervention`: unique `(tenant_id, intervention_id)`. This is the direct one-request-per-intervention blocker.
- `delivery_requests_tenant_id_idempotency_key_key`: unique `(tenant_id, idempotency_key)`. Preserve this.
- `delivery_attempts_delivery_request_id_attempt_number_key`: unique `(delivery_request_id, attempt_number)`. Preserve per-request attempt sequencing.

Observed RPC behavior:

- `create_delivery_request(..., p_idempotency_key, ...)` locks the parent `recovery_interventions` row `FOR UPDATE`, returns an existing request for the same idempotency key after checking its parent/context, and otherwise inserts a new `PENDING` request. Its current callers supply one intervention-level key.
- `authorize_delivery_request(...)` locks the request row, validates parent/context and `PENDING` status, rechecks tenant/flow/consent/suppression/provider prerequisites, and changes the request to `UNKNOWN` to claim it.
- `get_mailersend_token_for_delivery(...)` performs the one-time `provider_claimed_at IS NULL` claim before resolving and decrypting the provider credential. That timestamp is a credential-claim fence, not proof that the provider HTTP request started.
- `record_delivery_result(...)` locks the request and records append-only attempt history; terminal request states cannot be casually downgraded.

### Consequences for the concrete candidate migration

The earlier generic suggestion of "add a generation table" is insufficient by itself because the existing unique index still rejects a second request for the same intervention. The candidate implementation must explicitly address this:

1. Add `generation_number integer NOT NULL DEFAULT 1 CHECK (generation_number > 0)` to `delivery_requests`; existing rows are generation 1.
2. Replace `ux_delivery_request_intervention` with a unique index on `(tenant_id, intervention_id, generation_number)`. Keep the existing tenant/idempotency unique constraint.
3. Add a tenant/intervention-scoped retry-command ledger (or equivalent nullable unique key) so the same retry command always returns the same generation/request, even after a later generation exists.
4. Allocate N+1 only inside a transaction that locks the parent intervention first, checks the latest generation's trusted pre-provider failure and RELEASED reservation, and rejects all ambiguous/accepted/unresolved history.
5. Make every claim and egress authorization verify that the request's generation is still the highest/current generation for that parent.
6. Add a separate durable provider-egress-start marker. The existing `provider_claimed_at` cannot serve this purpose because credential resolution and envelope authorization occur after that claim but before the provider HTTP request.
7. Introduce an internal egress-authorization RPC after envelope validation and immediately before provider fetch. It must atomically verify current generation, claim ownership, consent/tenant/interlock/envelope preconditions, and set the egress-start marker. If the marker commits and the process crashes before fetch, the outcome remains ambiguous by design.
8. Keep the existing delivery-attempt and quota-reservation histories attached to immutable request IDs. A new generation gets a new request and reservation; it never resets an old row.

### Lock-order requirement

The live `create_delivery_request` already locks the intervention before inserting a request. Generation creation should reuse this parent lock. The other mutation paths must be audited and aligned to a single lock order before implementation:

`recovery_intervention → delivery_request → billing_account/reservation → delivery_attempt/event`

In particular, authorization currently locks the request before reading the intervention, and result recording locks the request. A migration that adds parent locking to only one path could introduce lock inversion. Before writing DDL, refactor the relevant candidate RPCs to use a consistent parent-first order and add two-session tests for retry-vs-claim, late-acceptance-vs-generation-create, and provider-result-vs-retry. Read-only lookup paths need not take these locks.

### Current implementation status

The reference-model tests and design document do not implement this migration. No generation column/index, retry-command ledger, egress-start RPC, or n8n generation routing has been added. The next engineering batch is a concrete migration design plus isolated PostgreSQL bootstrap/acceptance tests that model the live unique index and RPC lock order before any candidate production-shaped DDL is proposed.


## 12. Late-acceptance webhook integration gap — read-only audit, 2026-11-23

The quota settlement trigger's late-acceptance behavior has been proven by direct disposable-PostgreSQL attempt insertion. That is not equivalent to proving that the real MailerSend webhook can deliver the same evidence through the deployed RPC path.

Read-only inspection of `henvalt.process_mailersend_webhook_event` and `henvalt.record_delivery_result` found two integration blockers:

1. The webhook processor extracts the tenant tag and provider message ID, then resolves a delivery request by `tenant_id + provider + provider_message_id`. It does not currently resolve a delivery using the `delivery:<request UUID>` tag. A pre-provider failure normally has no provider message ID, so this route cannot correlate a later provider event to that request using its current lookup.
2. After a match, the webhook processor calls `record_delivery_result`. That RPC locks the request and rejects transitions from terminal `FAILED` status. A delayed `activity.delivered` event for a request previously marked FAILED therefore cannot follow the ordinary result-recording path.

The event processor inserts its provider-event row before linking/settling the delivery. The full transaction must be tested to establish whether a rejected settlement rolls back the event receipt and allows safe retry; do not assume webhook acknowledgement or event persistence is correct from the trigger test alone.

### Required candidate correction

Do not weaken the existing terminal-state transition rules globally. Add a narrowly scoped, authenticated provider-evidence settlement path that:

- verifies the provider webhook signature before reaching the database;
- resolves by exact tenant + immutable delivery tag/request identity when message ID is absent, and verifies the provider message ID/domain/recipient/time evidence when present;
- binds the event to one exact generation/request, never merely to an intervention or recipient;
- deduplicates the provider event by the existing provider/event hash identity;
- appends late-acceptance evidence and upgrades a RELEASED quota reservation to CONSUMED exactly once;
- preserves the original FAILED result and RELEASED audit event rather than rewriting history;
- freezes the intervention and creates a duplicate/contradictory-evidence incident if a supposedly pre-provider generation later has provider acceptance evidence;
- prevents a newer generation from entering provider egress after the contradiction is detected;
- handles concurrent webhook deliveries and retry-command transactions with the same canonical parent-first lock order.

If the provider webhook does not carry enough exact tags or metadata to correlate safely, do not guess. Keep the case unresolved for the documented provider activity reconciliation path.

### Acceptance tests added to the required matrix

- real webhook processor path for a provider message ID match;
- exact delivery-tag match when the original pre-provider attempt has no message ID;
- missing/ambiguous delivery tag rejected without attaching to a different request;
- delayed `activity.delivered` after pre-provider FAILED is durably recorded as contradictory evidence, consumes quota, and freezes the parent;
- duplicate webhook event is idempotent;
- webhook event insertion and settlement rollback/commit behavior is explicitly verified;
- race between late webhook settlement and retry-generation creation;
- race between late webhook settlement and a newer generation's egress-start marker.

**Verification boundary:** current quota CI proves the reservation trigger's direct late-acceptance transition and concurrency behavior. It does not prove the real MailerSend webhook path above. No production webhook, RPC, reservation, or delivery request was changed.


## 13. Isolated PostgreSQL transaction model — 2026-11-23

Added an executable PostgreSQL 17 model under `tests/delivery-generation-*`. It deliberately uses a separate `henvalt_test` schema and never connects to Supabase. The fixture mirrors the invariants that must hold before production-shaped DDL is written:

- unique tenant/idempotency identity and unique tenant/intervention/generation identity;
- parent-first row locking for generation allocation, claim, egress authorization and late provider evidence;
- a durable retry-command ledger;
- retry permission only when the previous request is FAILED, its latest attempt contains the exact server-owned `pre_provider` stage marker, its provider-egress marker is null, and its reservation is RELEASED;
- current-generation-only claim and egress;
- consent, tenant status, interlock and intervention freeze rechecks at both claim and egress boundaries;
- late acceptance consumes a released reservation while preserving the original FAILED request state and appending a separate provider-evidence attempt;
- contradictory acceptance freezes the parent and creates an incident;
- duplicate provider event identity is idempotent and cannot be rebound to another request;
- exact `tenant:<uuid>` + `delivery:<uuid>` tag correlation works when the original event has no message ID;
- wrong-tenant, missing/duplicate delivery tags, recipient mismatches and provider-message-ID rebinding are rejected.

The model is intentionally explicit that a provider HTTP response is not a pre-provider failure, even if it is an HTTP 4xx/5xx. A missing reservation, missing attempt, missing server marker, or unresolved/ambiguous state rejects retry.

### PostgreSQL acceptance and concurrency coverage

- `tests/delivery-generation-postgres-acceptance.sql`: 41 transaction-level acceptance cases.
- `tests/delivery-generation-concurrency-postgres.sh`: two independent sessions with distinct retry commands; exactly one generation may be allocated.
- `tests/delivery-generation-same-command-concurrency-postgres.sh`: two independent sessions with the same retry command; both must receive the same request ID.
- `tests/delivery-generation-late-acceptance-race-postgres.sh`: late acceptance takes the parent lock first; retry must wait and then be rejected.
- `tests/delivery-generation-retry-wins-late-acceptance-race-postgres.sh`: retry takes the parent lock first; late acceptance must wait, consume the prior reservation, freeze the parent, and prevent the new generation from claiming.
- `tests/delivery-generation-late-acceptance-before-egress-race-postgres.sh`: late acceptance wins the parent lock before the new generation's egress authorization; the egress fence must fail.
- `tests/delivery-generation-egress-before-late-acceptance-race-postgres.sh`: provider egress wins first; late acceptance then freezes the parent, and the in-flight generation remains quota-consumed/ambiguous with no second egress.

The dedicated workflow is `.github/workflows/delivery-generation-model-safety.yml`, using PostgreSQL 17. It is independent from the quota reservation workflow.

### Important boundary and blocker

This is an executable transaction contract, not a production migration or proof that the live RPCs already obey this lock order. The read-only production audit found that `record_delivery_result` currently locks a delivery request first and can later update its parent intervention. The model uses parent-first ordering. Before any generation RPC or egress fence is promoted into a production-shaped migration, all live writers that can acquire both locks must be reconciled to the same order, or a reviewed deadlock/retry protocol must be proven.

The existing `authorize_delivery_request` and `get_mailersend_token_for_delivery` code paths also need current-generation checks. The actual Edge Function needs a durable egress-authorization RPC after envelope validation and immediately before the MailerSend POST. The real MailerSend webhook path still needs exact delivery-tag correlation and the narrow late-acceptance settlement path described in section 12.

**No generation migration has been applied or added to the candidate migration directory in this batch. No production Supabase object, Edge Function, active n8n workflow, provider credential, or email was changed.**
