# V2 retry and duplicate-send safety audit — updated 21 November 2026

## Scope

Read-only review of candidate branch `prep/public-app-hardening-2026-11-15`, covering Recovery claim eligibility, lease completion, V2 checkout/pixel send-attempt state, MailerSend submission outcomes, and provider-event correlation. No live Supabase RPC, Edge Function, n8n workflow, Shopify API, or MailerSend API was called.

The candidate implementation is not deployed. The exact code revision previously validated by the full Identity V2 CI workflow is `281a5ad8fa3fae8d382df2f9010bdde439097628`; subsequent commits noted in the launch-readiness record are documentation-only. Revalidate the exact current PR head before relying on these results.

## Findings

### 1. A consumed send permit creates a durable retry exclusion

In `supabase/migrations/202611180042_shopify_recovery_work_claims_v2.sql`, the Recovery claim query excludes checkout work when any matching send-attempt row exists, and excludes pixel work when any matching pixel-attempt row exists. The exclusion is not limited to SUBMITTED attempts: AUTHORIZED, AMBIGUOUS, FAILED, and other persisted attempt states all suppress a new claim for that work item.

This is the key duplicate-send safety property after permit consumption. If a Delivery call times out after the Edge Function has consumed a one-use permit, a later Recovery tick cannot claim the same intervention/opportunity again because its send-attempt row now exists. If the Edge Function failed before an attempt row was created, the Recovery work item can be deferred and retried.

### 2. Lease deferral is bounded and now has a finite retry ceiling

The work-claim RPC validates retry intervals from zero through 24 hours. A DEFERRED outcome sets `next_attempt_at` and releases the lease; HANDOFF_ACCEPTED and TERMINAL set `completed_at`. The orchestrator confirms lease completion only when the RPC response contains both `finished: true` and the exact requested `outcome`; a lost or mismatched acknowledgement is reported as `LEASE_FINISH_UNCONFIRMED`.

The earlier audit identified unbounded retries before a send-attempt row existed. Candidate migration `202611200001_shopify_recovery_work_retry_ceiling_v2.sql` closes that gap: claim rows have a bounded maximum (default five, constrained 1–10); final DEFERRED attempts become EXHAUSTED; expired final leases are swept to EXHAUSTED rather than reclaimed; and an exact-store-scoped exhausted-work view supports operator review. Exhaustion is not treated as a successful handoff or successful delivery.

### 3. Ambiguous provider outcomes do not release cost reservations or trigger automatic resend

Checkout reconciliation migration `202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2.sql` preserves AMBIGUOUS attempt state and cost reservation, maps signed provider events to the original attempt, and explicitly reports that reconciliation performs no automatic resend. Stale AUTHORIZED checkout attempts become AMBIGUOUS without releasing their reservation or retrying.

Pixel migrations `202611180037`, `202611180038`, and `202611180039` implement the equivalent attempt-outcome, stale-attempt, and signed-event reconciliation boundaries. AMBIGUOUS is not converted to FAILED; stale AUTHORIZED attempts become AMBIGUOUS; provider events can settle the original attempt. The Delivery Edge Functions classify a timeout or post-request ledger failure as ambiguous and do not retry the provider POST.

### 4. Pixel provider-event correlation currently relies on MailerSend redelivery

The signed MailerSend webhook Edge Function first persists the verified event. It then calls `reconcile_mailersend_pixel_provider_event_v2`. If the provider message reference has not yet been committed to the pixel send-attempt row, the RPC returns `UNMATCHED` and the webhook responds HTTP 503 with `pixel_provider_event_waiting_for_attempt_correlation`. This is intentional: it asks MailerSend to redeliver the event rather than acknowledging an event that cannot yet be linked.

The repository's scheduled `n8n/v2-provider-event-reconciliation-runtime.mjs` currently runs the checkout unmatched-event reconciler and stale-checkout-attempt reconciler. Migration `202611180039` defines a per-event pixel reconciliation RPC, but no bounded batch RPC or scheduled pixel unmatched-event sweep was found in the candidate migration/runtime inventory reviewed here. Therefore pixel event recovery after the initial 503 depends on MailerSend's webhook retry behavior rather than an owner-controlled internal sweep.

MailerSend's current account-webhook documentation says non-2xx responses are retried with exponential backoff for up to about three days; prolonged failures can cause the webhook to be paused. It also notes that some failures are not retried. Source: https://developers.mailersend.com/api/v1/account/webhooks

This makes the immediate race recoverable while provider redelivery continues, but leaves a resilience gap if retries expire, the webhook is paused, or the provider's retry behavior changes. Before staging acceptance, add a bounded service-role batch reconciler for verified UNMATCHED pixel events and include it in the existing Delivery workflow's scheduled reconciliation branch (not a fourth workflow). The batch operation must preserve provider-account/store lineage, lock event and attempt rows consistently, be idempotent, never issue a send, and never release an ambiguous cost reservation. Add disposable-PostgreSQL tests for event-before-attempt, attempt-before-event, duplicate event replay, competing reconciliation, and event still unmatched after the attempt reference is available.

### 5. Conservative behavior has a delivery-reliability trade-off

Because the claim query excludes every existing attempt state, a FAILED attempt is also not automatically retried. This prevents a second send after an uncertain provider boundary, but means a definite pre-provider failure may require explicit, audited operator recovery rather than automatic retry. That is safer than blind resend, but should be visible in future operational tooling.

### 6. No provider-side idempotency guarantee is established by this audit

The checkout and pixel Edge Functions submit to MailerSend and rely on the durable one-use attempt/permit plus AMBIGUOUS state to prevent application-level resubmission. This audit did not establish a MailerSend idempotency-key contract for the Email API. Do not claim exactly-once provider delivery. The defensible property is conservative at-most-one application submission per persisted send attempt, with signed-event reconciliation where provider evidence is available.

## Validation and limitations

- Exact candidate source revision `281a5ad8fa3fae8d382df2f9010bdde439097628` passed Identity V2 workflow run [44799015266](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44799015266): full Node regression suite, secret scan, Deno checks, all 61 candidate migrations on disposable PostgreSQL, and concurrent recovery-claim/retry-exhaustion tests.
- Matching Shopify configuration workflow [44799015042](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44799015042) passed static/configuration migration validation; its deployment job was skipped.
- The current PR head must be checked again before treating this as exact-head CI evidence. CI fixtures are not production or staging runtime verification.
- This is a static candidate-code audit, not evidence that a live worker is running, that the former n8n workspace is accessible, that retention/redaction has been verified, or that production sending is stopped.
- No production or staging resource was changed. No deployment, workflow execution, provider request, or email send occurred. PR #6 remains open, draft and unmerged.
