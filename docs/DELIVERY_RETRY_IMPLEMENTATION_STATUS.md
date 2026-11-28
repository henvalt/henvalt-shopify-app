# Delivery retry-generation implementation status

Status: **candidate only; retry generations are not operational**.

## Implemented contracts

- The database candidate in PR #7 creates immutable delivery generations, retry jobs, lease renewal, retry-envelope loading, retry-aware authorization, and a retry-aware provider-egress fence.
- PR #7 now also adds `get_mailersend_token_for_delivery(uuid,uuid,uuid,text,integer)`. It validates the exact retry-job lease before reusing the existing eligibility, suppression, sender-domain, global-interlock, and Vault credential checks.
- PR #26's protected MailerSend Edge Function now routes generation 1 through the ordinary credential and egress RPCs, and generations 2/3 through the retry-lease overloads. It rejects missing, mismatched, or malformed retry identity.
- The ordinary dispatcher remains generation-one only and blocks generation 2/3.

## Not implemented / not accepted

- No worker yet claims `execute_delivery_retry_generation` jobs and carries their lease through envelope loading, authorization, provider invocation, result recording, and job completion.
- No complete trigger path yet converts a first-generation pre-provider rejection into an idempotently queued retry-evaluation job.
- No integrated test yet proves generation 1 -> generation 2 -> generation 3, including retries, late acceptance races, quota reservation and provider webhooks, through the actual Edge Function handlers.
- The current recovery executor claims only `execute_intervention`; it does not process retry-generation jobs.
- Therefore the retry path must remain disabled and must not be described as production-ready.

## Required completion order

1. Implement an idempotent database command that queues retry evaluation only for a proven pre-provider failure, with the failed request/attempt identity bound to the job.
2. Extend the existing HENVALT_DELIVERY worker (not a fourth logical workflow) to claim and process retry evaluation/send jobs using the exact worker lease.
3. Carry the lease identity into `load_delivery_retry_envelope`, `authorize_delivery_request_with_retry_lease`, the retry credential-release overload, and the five-argument `mark_mailersend_provider_egress_started` overload.
4. Record result and complete or enqueue the next bounded generation atomically where possible; never retry after egress started or an ambiguous provider outcome.
5. Add production-shaped PostgreSQL races and handler-level tests for duplicate workers, expired leases, generation limits, late provider acceptance, webhook settlement, and quota release.
6. Run the complete staging flow with the global provider-send interlock OFF first. Real provider sending requires separate explicit approval.

## Safety boundary

Do not deploy this candidate, create schedules, open the provider-send interlock, or send email as part of implementation work. Production remains untouched.
