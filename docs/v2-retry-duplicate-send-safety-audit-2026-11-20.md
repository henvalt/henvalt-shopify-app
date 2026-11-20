# V2 retry and duplicate-send safety audit — 20 November 2026

## Scope

Read-only review of the candidate branch `prep/public-app-hardening-2026-11-15`, focusing on Recovery claim eligibility, lease completion, V2 checkout/pixel send-attempt state, and provider-outcome reconciliation. This review did not call any live Supabase RPC, Edge Function, n8n workflow, Shopify API, or MailerSend API.

Code revision under review: `380a6526d38525321b34fc5711fe3a5db661d2f3`.
The branch's documentation-only head at review time was `ef25a877c0952a552f6ef0234294120ad215e88e`.

## Findings

### 1. A consumed send permit creates a durable retry exclusion

In `supabase/migrations/202611180042_shopify_recovery_work_claims_v2.sql`, the Recovery claim candidate query excludes checkout work when any matching row exists in `shopify_recovery_send_attempt_v2`, and excludes pixel work when any matching row exists in `shopify_pixel_send_attempts_v2`. The exclusion is not limited to SUBMITTED attempts: AUTHORIZED, AMBIGUOUS, FAILED, and other persisted attempt states all suppress a new claim for that work item.

This is the key duplicate-send safety property after permit consumption. If a Delivery call times out after the Edge Function has consumed a one-use permit, a later Recovery tick cannot claim that same intervention/opportunity again because its send-attempt row now exists. If the Edge Function failed before creating an attempt row, the Recovery work item can be deferred and retried.

### 2. Lease deferral is bounded; accepted/terminal outcomes complete the lease

The Recovery work-claim RPC validates retry intervals from zero through 24 hours. A DEFERRED outcome sets `next_attempt_at` and releases the lease; HANDOFF_ACCEPTED and TERMINAL set `completed_at`. The orchestrator bounds each retry delay to 24 hours and defaults invalid retry values to one hour. However, the claim table's `attempt_count` is incremented without a maximum, and the claim query does not filter on it. Therefore the delay is bounded, but the total number of retries is not: a repeatedly failing pre-permit handoff can be retried indefinitely.

The orchestrator now confirms lease completion only when the RPC response contains both `finished: true` and the exact requested `outcome`. A lost or mismatched acknowledgement is reported as `LEASE_FINISH_UNCONFIRMED`; it is not silently counted as completed.

### 3. Ambiguous provider outcomes do not release cost reservations or trigger automatic resend

Checkout reconciliation migration `202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2.sql` preserves AMBIGUOUS attempt state and cost reservation, maps signed provider events to the original attempt, and explicitly reports that reconciliation performs no automatic resend. Stale AUTHORIZED checkout attempts are changed to AMBIGUOUS without releasing their reservation or retrying.

Pixel migrations `202611180037`, `202611180038`, and `202611180039` implement the equivalent attempt-outcome, stale-attempt, and signed-event reconciliation boundaries. AMBIGUOUS is not converted to FAILED; stale AUTHORIZED attempts become AMBIGUOUS; provider events can settle the original attempt.

### 4. Conservative behavior has a delivery-reliability trade-off

Because the claim query excludes every existing attempt state, a FAILED attempt is also not automatically retried. This is conservative and prevents a second send after an uncertain provider boundary, but it means a definite pre-provider failure may require explicit, audited operator recovery rather than automatic retry. That is safer than blind resend, but should be made visible in future operational tooling.

A separate retry-policy gap remains: repeated failures before a send-attempt row exists can loop indefinitely. The current code bounds the wait between attempts, not the cumulative retry count. Before any staging acceptance, add a finite attempt ceiling with an explicit exhausted/dead-letter state, preserve tenant/store scope, expose an operator-review path, and test both the final permitted retry and the no-further-claim condition. Do not silently convert exhaustion into HANDOFF_ACCEPTED or TERMINAL.

## Validation and limitations

- The exact source revision above passed the repository Identity V2 CI suite and the Shopify static/disposable-migration validation suite.
- The documentation-only head's CI reruns also completed successfully: Identity V2 validation passed; Shopify static and disposable-migration validation passed; Shopify deployment was skipped.
- The disposable database CI job exercises candidate migrations and a range of identity, privacy, attribution, cost, and recovery contracts. This review did not independently execute a new production or staging test.
- This is a static candidate-code audit, not evidence that a live worker is running, that the former n8n workspace is accessible, that retention/redaction has been verified, or that production sending is stopped.
- No production or staging resource was changed. No deployment, workflow execution, provider request, or email send occurred. PR #6 remains unmerged.
