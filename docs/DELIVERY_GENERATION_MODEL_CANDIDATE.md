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
