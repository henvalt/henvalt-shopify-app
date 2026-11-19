# Shopify V2 recovery → n8n execution contract

**Status:** preparation-only engineering contract, 19 November 2026. This document is not a production change request or deployment authorization.

## Verified live topology

Read-only inspection of the active workflows confirms:

| Workflow | ID | Active version | Responsibility today |
|---|---|---|---|
| `HENVALT_INGEST` | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | Shopify webhook verification, tenant resolution, canonical event projection and legacy event fan-out |
| `HENVALT_RECOVERY` | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | Legacy job/intervention claiming, AI copy, legacy message/token creation, delivery subworkflow call |
| `HENVALT_DELIVERY` | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | Legacy authorization, MailerSend provider call, provider result recording, tracking/unsubscribe and inbound routes |

All three were active when inspected. Their live versions were not changed, executed, activated, deactivated or published by this work.

## Critical compatibility finding

The active Recovery → Delivery contract is not compatible with the new V2 delivery endpoints:

- Legacy Recovery constructs `tenant_id`, `delivery_request_id`, recipient, subject, HTML/text, tracking and unsubscribe context.
- Legacy Delivery requires those legacy fields, calls `authorize_delivery_request`, then sends through `henvalt-mailersend-delivery`.
- V2 checkout delivery accepts exactly one field: `intervention_id`.
- V2 pixel delivery accepts exactly one field: `opportunity_id`.
- V2 Edge Functions resolve their own trusted context, recipient, sender, consent, authorization, cost reservation, message rendering and provider submission. Passing the legacy payload is rejected.

Therefore, the V2 path must not be grafted into the existing legacy send nodes by changing only the endpoint URL. It needs a separate, explicit branch and result adapter.

## Required V2 Recovery schedule sequence

The scheduled Recovery workflow must execute these database functions in order, with bounded limits and a stable worker identifier:

1. `refresh_shopify_checkout_recovery_candidates_v2(limit)`
2. `promote_shopify_checkout_recovery_candidates_v2(limit)`
3. `refresh_shopify_pixel_recovery_candidates_v2(inactivity_minutes,max_age_hours,limit)`
4. `promote_shopify_pixel_recovery_candidates_v2(limit)`
5. `materialize_shopify_checkout_interventions_v2(limit)`
6. `claim_shopify_recovery_work_v2(worker_id,limit,lease_seconds)`

Migrations 042–043 by filename establish the shared claims and checkout materializer. The three 19 November files establish safe message context, sender-profile preflight and MailerSend test-signature compatibility. The complete ordered CI manifest now contains 59 candidate migration files; its final files are `202611190004_shopify_checkout_candidate_terminal_state_v2.sql` and `202611190005_shopify_checkout_provider_submission_gate_v2.sql`. The latter rechecks exact-store install, checkout, consent, suppression, privacy, sender and reserved-cost state immediately before checkout provider submission. These functions are service-role-only. No live database has been migrated by this branch work.

### Claim handling invariants

- Claim output is opaque work identity and lease metadata only; it must not contain recipient email or message body.
- Work types are exactly `CHECKOUT_INTERVENTION` and `PIXEL_OPPORTUNITY`.
- The private database lease row retains tenant/store/work/lease lineage. n8n receives only the three opaque claim fields and must never treat them as delivery authorization.
- Checkout delivery receives `intervention_id`; pixel delivery receives `opportunity_id`.
- Never derive a pixel intervention or checkout identity from the other work type.
- Every claimed item must reach exactly one finish outcome: `HANDOFF_ACCEPTED`, `TERMINAL`, or `DEFERRED`.
- `DEFERRED` must use the lease's retry semantics and must not be recorded as completed.
- On transport timeout after invoking an Edge Function, do not assume no send occurred. Defer/reconcile; never blindly reissue a new send.
- A stale worker may not finish a reclaimed lease. The database is authoritative.

## Required Delivery subworkflow contract

Keep the existing Recovery → Delivery subworkflow relationship, but introduce a V2-only opaque payload path.

Input to the V2 adapter is restricted to:
```json
{
  "work_type": "CHECKOUT_INTERVENTION | PIXEL_OPPORTUNITY",
  "work_id": "<uuid>",
  "lease_id": "<uuid>",
  "worker_id": "<opaque worker id>",
  "correlation_id": "<uuid>"
}
```

Before the Edge Function call, validate the enum and UUID shapes. Do not include tenant ID, recipient, subject, HTML, text, product details, tokens, or provider secrets in the payload.

Routing is deterministic:
- `CHECKOUT_INTERVENTION` → `POST /functions/v1/henvalt-shopify-contact-delivery-v2`, JSON body `{"intervention_id":"<work_id>"}`.
- `PIXEL_OPPORTUNITY` → `POST /functions/v1/henvalt-shopify-pixel-delivery-v2`, JSON body `{"opportunity_id":"<work_id>"}`.

Each request must use its distinct server-held delivery authorization token. Never place either token in node output, workflow input, execution logs, or error text. The Edge Functions fail closed unless `HENVALT_V2_MAILERSEND_EVENTS_READY=true` and their server-side sender/provider configuration is ready.

### Result classification

The Edge Function HTTP result is not interchangeable with an email delivery receipt.

- 2xx response with `accepted: true` and an allowlisted status (`submitted`, `accepted`, `handed_off`, `ambiguous_provider_submission`, `provider_accepted_record_pending`, or `provider_outcome_requires_reconciliation`): `HANDOFF_ACCEPTED`. An ambiguous/pending 202 means the Edge Function already crossed the provider boundary and owns reconciliation; Recovery must complete the lease so Delivery is never invoked again for that work item.
- Explicit ineligible/authorization/context failure (4xx): classify as `TERMINAL` only for documented permanent reasons. A configuration or policy-not-ready response should be deferred/retried only where the DB contract explicitly allows it; otherwise stop and alert rather than spin. Invalid-request 400/422 may be terminal when the function contract proves permanent invalidity; gateway-level 404/410 must defer and alert because a missing/retired function route must never terminalize every claimed opportunity.
- 401/403: configuration/security incident; do not retry in a tight loop.
- 429/5xx/network timeout/invalid JSON or any response without explicit accepted state: `DEFERRED`. A 502 with `accepted: false` and `error: provider_submission_rejected` is `TERMINAL` because the Edge Function has already recorded the definite provider rejection.
- Never retry a possibly submitted provider call as a fresh send until the ambiguous-attempt reconciler determines the outcome.

Recovery finishes the claim through `finish_shopify_recovery_work_claim_v2(p_lease_id,p_worker_id,p_outcome,p_retry_after)` only after the synchronous Delivery subworkflow returns its sanitized result. Delivery never finishes the lease. The RPC's result must be checked. A rejected/stale lease finish is an operational error, not success.

## MailerSend event cutover: one receiver only

The active legacy Delivery workflow currently exposes a MailerSend Events Webhook and processes events through legacy signature verification and `henvalt.process_mailersend_webhook_event`. V2 delivery additionally requires the signed provider events to reach `henvalt-mailersend-webhook-v2` with the original raw request body and MailerSend signature.

Before V2 delivery is enabled:
1. Configure MailerSend's event URL to the V2 Edge Function URL directly.
2. Verify the exact signature header and raw-body preservation with MailerSend's URL validation event and a real signed test event.
3. Confirm V2 webhook reconciliation accepts test events without persisting them as customer events.
4. Confirm actual events correlate to checkout or pixel attempts, including the unmatched-event retry behavior.
5. Ensure the old n8n MailerSend Events Webhook is no longer configured as a receiver for the same event stream.
6. Do not disable/remove the legacy receiver until the new route has passed its signed verification test and the provider endpoint change is approved.

Never proxy parsed/re-serialized JSON to the V2 webhook: signature verification requires the original raw bytes. Do not process one provider event in both legacy and V2 handlers.

Inbound MailerSend replies are a separate route and are not covered by this event cutover. Preserve the existing inbound route until a separate migration plan exists.

## Legacy nodes that must not be on the V2 send path

The current Recovery workflow has a legacy AI copy-generation path, tracking/unsubscribe token creation, `render_and_queue_message`, `create_delivery_request`, and a legacy Delivery payload builder. Do not run those nodes for V2 claimed work: V2 rendering and delivery context are resolved inside the Edge Functions and use their own authorization and provider event lifecycle.

The current Delivery workflow also contains a manual one-off test email branch with a hard-coded historical delivery request and recipient address. It is not part of V2 and must be disabled or removed from the eventual production workflow after its purpose and authorization are reviewed. Do not execute it as part of a V2 dry run.

## Three-workflow responsibility after cutover

- **HENVALT_INGEST:** retain Shopify webhook raw-body verification, exact shop-to-tenant resolution, idempotent canonical event projection, order/uninstall/privacy event processing and the current event response contract. Do not add a second Shopify event consumer for the same topic.
- **HENVALT_RECOVERY:** add the V2 scheduled discovery/materialization/claim sequence and lease-safe handoff. Legacy recovery processing may remain only for explicitly supported legacy event classes during a controlled migration window; do not allow both engines to claim the same V2 work.
- **HENVALT_DELIVERY:** retain existing public tracking, unsubscribe and inbound-reply routes where still needed. Add an internal V2 subworkflow route for opaque work IDs and distinct Edge Function dispatch. Remove legacy send path from V2 work only after equivalence tests and explicit cutover approval.

## No-send dry-run acceptance suite

A V2 dry run must use a disposable database/project or a test-only database transaction and stub provider transport. It must prove:

1. Empty candidate set → no claim and no provider call.
2. Checkout candidate → only checkout intervention is materialized and claimed.
3. Pixel candidate → only pixel opportunity is claimed; no checkout intervention is fabricated.
4. Same item claimed concurrently by two workers → exactly one active lease.
5. Deferred claim is reclaimed with a fresh lease ID; old lease cannot finish.
6. Wrong work type, malformed UUID, wrong-store ID, missing authorization token → no provider call.
7. Inactive tenant/app/connection, no sender, unverified sender, no policy/consent/contact evidence, suppression, recovered order, or missing cost entitlement → no provider call.
8. MailerSend preflight disabled/unverified unsubscribe insertion → no provider call.
9. 2xx accepted result → lease completion only after explicit accepted response.
10. 4xx permanent ineligibility → terminal only when allowlisted.
11. Timeout/5xx/429/malformed response → deferred or ambiguous reconciliation; never a blind duplicate send.
12. Signed MailerSend test event → signature verified, no customer event persisted.
13. Signed delivery event before attempt correlation → retryable unmatched response; after correlation → one reconciliation.
14. Duplicate signed event → idempotent no-op.
15. No recipient email, Shopify token, provider token, raw message body or authorization token appears in n8n execution data/logs.

The test harness must intercept outbound network calls and fail the test if any MailerSend request escapes the stub. A test named "dry run" is not sufficient unless the provider call is structurally impossible.

## Production gates — not satisfied by this document

- Candidate migrations 001–043 and 19 November migrations are not proof of production application. Reconcile live migration history before any apply.
- V2 Edge Functions are not proven deployed with the required secrets/configuration.
- The three live n8n workflows have not been changed to this contract.
- The V2 MailerSend endpoint and signed events have not been verified end-to-end.
- Shopify app ownership/public app identity, webhook subscriptions, store activation and valid test order remain separate launch gates.
- No production send, billing, PR merge or deployment is authorized by this preparation work.


## 19 November — offline Recovery→Delivery acceptance matrix

Added `tests/n8n-v2-offline-acceptance.test.mjs`, which composes the candidate Recovery runtime, Delivery adapter and injected fake network in one test process. The matrix exercises:
- 401/403 auth failures, 409 policy/preflight rejection, 429 throttling and 503 Edge unavailability → deferred lease outcome.
- 400/422 permanent invalid requests → terminal only when documented. 404/410 missing or retired routes → deferred with alert.
- Explicit recorded provider rejection (502) → terminal; accepted-but-ambiguous 202 → handoff accepted so the Edge reconciler owns the result.
- Malformed Edge JSON and transport exceptions → bounded deferral with sanitized result.
- Lease-finisher invocation and no MailerSend host escape for each composed scenario.

This is an **offline adapter/orchestration acceptance suite**, not a substitute for the database-backed no-send cases in the 15-point plan above. It does not prove production consent, store isolation, sender verification, cost reservation or provider webhook behavior. Provider transport is structurally absent from the test doubles; production Edge Functions are not called.


## Lease-finish acknowledgement is part of tick success

The Recovery runtime now reports `accepted: false` with status `LEASE_FINISH_UNCONFIRMED` whenever any claimed item's finish RPC does not confirm `finished: true`. It does not report a completed scheduler tick merely because Delivery returned an accepted handoff. The regression test proves that an accepted handoff plus an unconfirmed lease finish remains an operationally incomplete tick. Operators must inspect/reconcile the lease rather than treat that tick as successful.


## Batch validation and lease-finisher transport failure

Recovery now validates every item in the claimed batch (work enum, work UUID, lease UUID and duplicate work key) before the first Delivery handoff or lease mutation. A malformed later item therefore cannot cause a partially processed batch.

Each lease-finisher call is also isolated. If the finisher throws or its response is lost, Recovery does not blindly retry the finish RPC (it may already have committed); it marks that lease `lease_finish_unconfirmed`, continues processing the remaining claimed items, and returns `accepted:false` / `LEASE_FINISH_UNCONFIRMED` for the overall tick. The operator must reconcile the lease state before considering the run complete.
