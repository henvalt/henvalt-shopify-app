# HENVALT Shopify privacy lifecycle

This implementation is staged in PR #2. It is not deployed to the production Supabase project or released as a Shopify app version.

## Components

- `henvalt-shopify-privacy`: accepts Shopify compliance webhooks, verifies the raw-body Shopify HMAC, persists an idempotent receipt, and invokes the tenant-scoped database operations.
- `henvalt-privacy-export`: lists and downloads customer exports for an authenticated HENVALT workspace OWNER or ADMIN. It validates the access token through Supabase Auth and checks the tenant membership in the database.
- `202611140002_shopify_privacy_request_queue.sql`: creates the service-role-only webhook receipt queue.
- `202611140003_shopify_customer_privacy_rpcs.sql`: adds tenant-scoped export, customer redaction, and shop redaction RPCs.
- `202611140004_shopify_privacy_export_storage.sql`: adds service-role-only temporary export storage and an expiry purge RPC.
- `202611140005_schedule_privacy_export_purge.sql`: registers a recurring Supabase Cron job to purge expired export bundles every 15 minutes.

## Deployment order

1. Enable Supabase Cron (`pg_cron`) from Dashboard → Integrations → Cron. The migration deliberately fails closed if the extension is not enabled.
2. Apply migrations 002, 003, 004, and 005 in order. Migration 005 schedules the idempotently named `henvalt-privacy-export-expiry-purge` job every 15 minutes.
3. Deploy `henvalt-shopify-privacy` with JWT gateway verification **disabled**. It authenticates requests with Shopify's HMAC signature.
4. Deploy `henvalt-privacy-export` with JWT gateway verification **disabled** as well. It performs its own Supabase Auth user lookup and OWNER/ADMIN membership check; disabling gateway JWT is required for its browser CORS preflight to reach the function.
5. Confirm both functions are deployed and test valid/invalid HMAC, an owner export download, a customer redaction, and a shop redaction against a disposable test tenant.
6. Only then release the Shopify app version containing the three mandatory compliance topics.

Both functions use the existing Supabase project environment variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_ANON_KEY`; the webhook receiver additionally needs `SHOPIFY_API_SECRET`.

## Scheduler prerequisite

- The connected production database currently has neither `pg_cron` nor the `cron.job` scheduler table enabled. This was confirmed with a read-only extension/catalog query.
- Migration 005 requires the extension to be enabled first, then registers the named purge job every 15 minutes. It is safe to re-apply because `cron.schedule` upserts by job name.
- After deployment, verify the job exists in `cron.job` and has successful executions in `cron.job_run_details`. Until those checks pass, do not claim scheduled cleanup is live.
- Enabling the extension and applying migration 005 changes production database configuration. Keep this separate from the GitHub PR and obtain explicit approval before doing it.

## Data handling

- Customer exports are retained in a service-role-only JSONB column for up to 30 days and are delivered as an authenticated JSON download. They are not emailed.
- Export payloads are cleared when expired. Opportunistic cleanup also runs on verified privacy webhooks and owner privacy-page/download requests. Once migration 005 is applied and its Cron job is verified, a scheduled purge runs every 15 minutes; expiry deletion may therefore occur up to 15 minutes after the expiry timestamp.
- Unmatched shop/customer requests remain in `REVIEW_REQUIRED` instead of being silently discarded. Unmatched customer data requests are visible in the merchant privacy page as requiring manual review; only ready exports expose a download action.
- `customers/data_request` and `customers/redact` support Shopify payloads containing only a customer email (no customer ID). Exports include email-matched checkout/order activity even when no customer row exists, and raw Shopify-ID keyed events when the ID is supplied. Redaction also anonymizes linked checkout/order records and clears ID-keyed event payloads within the tenant, even when no customer row exists.
- Customer redaction removes linked customer, event, message, delivery, tracking, suppression, and audit/error payloads within the tenant.
- Shop redaction sanitises and detaches the receipt before deleting the tenant and its tenant-scoped records.

## Safety boundary

Do not apply these migrations, deploy either function, or release the Shopify app version until the disposable-tenant end-to-end tests pass and the merchant export delivery process is reviewed. Recovery email sending is unrelated and remains disabled.
