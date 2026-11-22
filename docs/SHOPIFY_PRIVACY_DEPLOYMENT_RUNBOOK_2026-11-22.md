# Shopify privacy handler deployment runbook — 2026-11-22

**Status: candidate only. No production deployment is authorized or performed by this document.**

## Deployment target and source integrity

- Supabase project: `ocyplckdojdubyrsxcxa`
- Function slug: `henvalt-shopify-privacy`
- Deployable candidate source: `supabase/functions/henvalt-shopify-privacy/index.ts`
- Deployed v1 audit baseline: `supabase/audit-baselines/henvalt-shopify-privacy-v1.ts`
- Shopify compliance endpoint already declared in candidate `shopify.app.toml`: `https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-privacy`
- The handler must remain `verify_jwt=false` at the Supabase gateway because it performs Shopify HMAC verification over the exact raw body itself. Deploy with `--no-verify-jwt`; do not change the handler to rely on a Supabase user JWT.

## Required order

1. Take a fresh database backup and confirm the project ID and current migration head.
2. Run disposable PostgreSQL 17 acceptance first. Required candidate migration order:
   - `202611220001_shopify_privacy_claim_and_minimization.sql`
   - `202611220002_shopify_privacy_redaction_guards.sql`
   - `202611220003_shopify_privacy_retention_cron.sql`
   - `202611220004_shopify_privacy_signed_payload_idempotency.sql`
   - `202611220005_shopify_privacy_queue_worker.sql`
3. Apply only those reviewed migrations, in order, using a controlled SQL migration process. Do not run an unrestricted `supabase db push` for the whole candidate branch: it contains other unrelated candidate migrations that have not been approved for production.
4. Verify `cron.job` contains exactly one active `henvalt-shopify-privacy-queue-worker` schedule with the expected one-minute cadence and command.
5. Deploy only the `henvalt-shopify-privacy` function from the candidate source with gateway JWT verification disabled. Do not deploy the audit-baseline file or deploy all functions indiscriminately.
6. Verify the deployed function source/version and run a signed, non-destructive privacy data-request test against an isolated Shopify development store. Verify invalid HMAC returns 401, valid request persists once, duplicates are idempotent, and the worker processes the queue.
7. Verify customer-redact against synthetic tenant data in isolated staging, including no-match, customer-ID-only, email-only, delivery-only, and retry cases. Verify shop-redact after uninstall with signed shop identity matching the retained inactive connection.
8. Verify the owner-authenticated export pull route, expiry, and delivery audit semantics. The current export endpoint marks `result_delivered_at` before response receipt and does not itself prove merchant receipt; keep data requests in review until an acknowledged delivery path is implemented and verified.
9. Only after all checks pass, deploy the candidate `shopify.app.toml` configuration so Shopify subscribes to all three mandatory compliance topics. This step changes the Shopify app configuration and must be explicitly approved.
10. Confirm Shopify webhook delivery logs for all three topics and retain evidence for review.

## Rollback boundaries

- Do not drop privacy queue columns, remove signed-payload hashes, or remove lease fields during rollback; preserve receipts and audit history.
- If the worker fails, stop the new worker schedule only after ensuring an alternative durable processor is running. Do not return successful acknowledgements while no processor is available.
- If the handler deployment fails, restore the last known-good function version, but do not deploy the audit baseline without a documented risk decision.
- Do not activate production email sending or modify the three active n8n workflows as part of privacy cutover.

## Outstanding release gates

- Candidate migrations and function must pass the full current CI workflow.
- Export delivery requires a merchant acknowledgement flow; response initiation is not receipt.
- Full isolated end-to-end lifecycle evidence is still required.
- Candidate TOML declaration is source-only; production Shopify configuration remains unchanged.
