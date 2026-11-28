# Staging delivery retry worker contract

Status: implementation contract only. This document does not enable retries, deploy a worker, schedule jobs, or authorize provider sending.

## Why a dedicated worker is required

The ordinary `henvalt-delivery-dispatcher` is intentionally generation-one only. It selects ordinary pending requests and does not claim `execute_delivery_retry_generation` jobs. Generations 2 and 3 must not be routed through that path.

The database migration `202611240001_delivery_retry_generation_jobs.sql` creates the retry ledger and the lease-aware authorization, envelope-loading, credential-release, and final-egress contracts. The retry worker must preserve the exact claimed job identity from claim through provider egress.

## Job contract

Claim with the existing `claim_next_job` RPC and the exact type list:

```json
{
  "p_worker_id": "<unique worker id>",
  "p_job_types": ["execute_delivery_retry_generation"]
}
```

The claimed payload must contain valid UUIDs for `tenant_id`, `intervention_id`, `delivery_request_id`, and an integer `generation_number` of 2 or 3. It also contains `source_retry_command_id`. Reject malformed payloads; never infer missing identity from a different tenant or request.

## Required sequence

1. Read global `provider_send_control` first. If disabled, return PAUSED without claiming a job or contacting MailerSend.
2. Claim exactly one retry job. Generate a unique worker ID per invocation.
3. Call `load_delivery_retry_envelope` with `p_job_id`, `p_worker_id`, `p_tenant_id`, `p_intervention_id`, `p_delivery_request_id`, and `p_generation_number`. Require exactly one row. This validates the lease, generation mapping, current intervention state, no later generation, and no provider-attempt/event evidence. It also safely reclaims a retry request that was left UNKNOWN before the egress marker.
4. Resolve the tenant's active MailerSend sending identity and validate that the envelope recipient and sender configuration are still eligible. Do not copy message content into logs.
5. Call `authorize_delivery_request_with_retry_lease` with the envelope identity, recipient and idempotency key plus the exact retry job ID, worker ID and generation. Require `can_send=true`; otherwise do not call the provider.
6. Invoke the existing protected `henvalt-mailersend-delivery` function, passing the immutable envelope and all three retry identity fields. That function must use the retry overload of `get_mailersend_token_for_delivery` and the retry overload of `mark_mailersend_provider_egress_started`. The final egress fence must be the last database operation before the MailerSend HTTP request.
7. Interpret outcomes conservatively:
   - explicit provider HTTP response: record ACCEPTED or FAILED with the provider response stage;
   - explicit pre-provider rejection: record REJECTED, with retryable=false unless a separately reviewed policy says otherwise;
   - ambiguous transport or ambiguous egress-fence response: record UNKNOWN and do not automatically retry;
   - missing/unclassified response: leave blocked for reconciliation; never assume failure means no email was sent.
8. Complete the exact claimed job only after the result has been durably recorded. If the worker loses its lease or the result write is ambiguous, do not issue another provider call. Let stale-job repair and reconciliation handle it.

## Database RPC signatures

- `claim_next_job(p_worker_id, p_job_types)`
- `load_delivery_retry_envelope(p_job_id, p_worker_id, p_tenant_id, p_intervention_id, p_delivery_request_id, p_generation_number)`
- `authorize_delivery_request_with_retry_lease(p_tenant_id, p_delivery_request_id, p_intervention_id, p_recovery_id, p_opportunity_id, p_recipient, p_idempotency_key, p_retry_job_id, p_retry_worker_id, p_generation_number)`
- `get_mailersend_token_for_delivery(p_tenant_id, p_delivery_request_id, p_retry_job_id, p_retry_worker_id, p_generation_number)`
- `mark_mailersend_provider_egress_started(p_tenant_id, p_delivery_request_id, p_retry_job_id, p_retry_worker_id, p_generation_number)`
- `record_delivery_result(...)`
- `complete_job(p_job_id, p_worker_id)`

All RPCs must use PostgREST `accept-profile: henvalt` and `content-profile: henvalt` where a request body is sent. All calls are service-role only and must remain server-side.

## Required acceptance tests before enabling

- wrong tenant, job ID, worker ID, delivery ID, and generation each fail closed;
- expired or superseded lease cannot authorize or pass final egress;
- two workers racing for one retry job cannot both authorize;
- generation 2 and 3 can only send through the retry worker;
- generation 4 is impossible;
- frozen intervention, unsubscribe/suppression, inactive tenant/store, or global send-off blocks delivery;
- crash after envelope load but before authorization is safely recoverable;
- crash after authorization but before egress does not duplicate a provider call;
- ambiguous egress RPC response produces UNKNOWN and no second provider call;
- provider acceptance followed by result-write timeout is reconciled without resend;
- late provider acceptance freezes later generations and preserves append-only evidence;
- quota reservation is consumed/released exactly once;
- no customer PII, message body, or provider credential appears in logs.

## Current boundary

This contract is not a completed worker. No retry worker, scheduler, staging deployment, or real provider acceptance is implied. Keep provider sending globally disabled until the integrated staging acceptance suite passes and a separate explicit approval is given.
