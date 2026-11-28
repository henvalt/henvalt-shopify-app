# Staging recovery scan worker

Status: candidate-only implementation. It is not deployed, scheduled, or enabled.

## Purpose

The Edge Function `henvalt-recovery-scan` is a staging-only, service-role-authenticated orchestrator for the three existing idempotent candidate processors:

1. `henvalt.process_abandoned_checkout_candidates(60, 48, 100)`
2. `henvalt.process_abandoned_cart_candidates(60, 48, 100)`
3. `henvalt.process_browse_abandonment_candidates(60, 48, 100)`

It calls them sequentially, stops on the first upstream failure, and does not return candidate/customer data. The batch size and age/inactivity parameters are fixed server-side; callers cannot override them.

## Safety boundaries

- The handler accepts requests only when `SUPABASE_URL` exactly equals the isolated staging project URL.
- The caller must present the service-role bearer token. Supabase Edge Function JWT verification remains enabled by default.
- No provider credential, MailerSend endpoint, billing RPC, or delivery worker is called.
- The handler does not claim or execute `execute_intervention` jobs.
- No cron schedule is created by this change.
- Production is not a valid target and the handler fails closed if configured against production.

## Required acceptance before staging deployment

- Run `node --test tests/henvalt-recovery-scan-handler.test.mjs`.
- Type-check the Edge Function with the repository's Deno check workflow.
- Confirm the three RPC signatures and service-role execute grants in the isolated staging database.
- Deploy only to the staging Supabase project.
- Invoke manually with a staging service-role token and confirm the response contains only stage completion names.
- Verify the opportunity/intervention/job counts and idempotency across two consecutive runs.
- Keep provider sending disabled. Do not schedule this function until the intervention execution/delivery path is independently verified.

This worker is the first isolated building block for the recovery processing plane; it is not a claim that HENVALT_RECOVERY or delivery is complete.
