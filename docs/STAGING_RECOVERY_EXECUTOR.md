# Staging recovery executor candidate

## Purpose

`henvalt-recovery-executor` processes at most one `execute_intervention` job per invocation. It is the execution layer between the existing recovery candidate scanners and the protected delivery worker.

## Sequence

1. Authenticate the caller with the staging Supabase service-role bearer.
2. Claim one `execute_intervention` background job using `henvalt.claim_next_job`.
3. Claim the intervention with `henvalt.claim_intervention_for_send`.
4. Load authoritative context with `henvalt.get_recovery_worker_context`.
5. Recheck tenant, Shopify connection, recovery/opportunity state, consent, suppression, sender configuration, schedule, idle window, channel and destination.
6. Require an HTTPS `HENVALT_PUBLIC_ACTIONS_BASE_URL` before creating tracking or unsubscribe tokens.
7. Create tracking and unsubscribe tokens using existing database RPCs.
8. Generate structured copy through the separate staging-only `henvalt-groq-generate` Edge Function.
9. Validate the exact JSON schema and reject generated URLs.
10. Render the branded HTML email and create the message and idempotent delivery request.
11. Complete the claimed job. Failures return the intervention to READY where appropriate and schedule a bounded retry.

## Deliberate safety boundaries

- The code is pinned to staging project `xidhtmrfvsgfmyltjuja`; a production URL fails closed.
- It requires service-role authentication and keeps tenant data server-side.
- It only claims `execute_intervention` jobs.
- It does not call MailerSend or the delivery Edge Function. It only creates a delivery request.
- It does not change provider sending controls, billing, cron schedules, or production resources.
- It is not deployed or scheduled.

## Required dependency before integrated staging

The staging project currently has no `henvalt-public-mail-actions` endpoint. The historical n8n candidate used a placeholder URL for track/unsubscribe links. This executor therefore refuses to create tokens or messages unless a real HTTPS public actions origin is configured. Do not set that environment variable to a placeholder. A separate public tracking + unsubscribe endpoint must be implemented and tested first.

## Remaining verification

- Add a staging-only `GROQ_API_KEY` to the generation gateway secret store before a live AI test.
- Implement and test the public track/redirect and unsubscribe endpoints.
- Verify the exact `delivery_mode` and sender identity contract against a real staging tenant.
- Prove OAuth, signed webhook, candidate creation, execution, delivery-request processing, and attribution against the free Shopify development store.
- Add a scheduler only after those tests pass. Keep provider sending disabled until explicit approval.
