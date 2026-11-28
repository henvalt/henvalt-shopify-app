# Staging delivery dispatcher candidate

## Purpose

`henvalt-delivery-dispatcher` polls at most one due pending MailerSend email request and hands its trusted envelope to the existing protected `henvalt-mailersend-delivery` Edge Function. It is the dispatch adapter for the existing delivery lifecycle, not a replacement provider implementation.

## Sequence

1. Require the staging service-role bearer and staging Supabase project.
2. Read the global `provider_send_control` interlock. If missing or false, return PAUSED before selecting a request.
3. Select one due `PENDING` EMAIL/MailerSend delivery request, restricted to generation 1. Generation 2+ is explicitly blocked until a dedicated retry worker carries the exact claimed retry-job lease.
4. Load the intervention's authoritative delivery context through `get_intervention_delivery_context`.
5. Load the tenant sender profile and matching active sending identity; derive the exact sender display name and reply-to expected by the database envelope guard.
6. Render the legal sender footer and plain-text alternative through the database's own rendering RPCs.
7. Call the protected delivery Edge Function with the complete envelope. That function rejects retry generations before credential release, obtains the tenant/provider credential, then commits `mark_mailersend_provider_egress_started` immediately before MailerSend HTTP. An ambiguous egress-fence response is treated as UNKNOWN and is never sent again automatically.
8. Record accepted, failed, rejected, or ambiguous results through `record_delivery_result`.

## Safety boundaries

- Staging project is hard-pinned to `xidhtmrfvsgfmyltjuja`.
- Global sending disabled means PAUSED; no delivery request is selected and no provider function is called.
- The protected delivery function remains the only code allowed to release the provider credential and make MailerSend egress.
- The ordinary dispatcher and protected worker both reject generation 2+; retry generations require the separate retry-job lease contract and are not operational yet.
- The one-way provider egress marker is committed before MailerSend HTTP. Ambiguous provider transport or an ambiguous egress-fence response is recorded as UNKNOWN and is not retried automatically.
- No scheduler, deployment, provider enablement, billing change, or production mutation is included.
- The worker handles one request per invocation and is not yet activated.

## Remaining verification

- Run against a real staging tenant and sender identity with provider sending disabled; confirm it pauses before any delivery claim.
- Verify the exact provider envelope and MailerSend webhook lifecycle against a controlled test recipient before any send approval.
- Implement and separately test a retry dispatcher that carries `delivery_retry_jobs` identity through `authorize_delivery_request_with_retry_lease` and the retry-specific egress RPC.
- Verify late provider acceptance reconciliation against the append-only generation incident ledger.
- Add a scheduler only after explicit approval and successful staging end-to-end checks.