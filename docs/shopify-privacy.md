# HENVALT Shopify privacy lifecycle

This implementation is staged in PR #2. It is not deployed to the production Supabase project or released as a Shopify app version.

## Components

- `henvalt-shopify-privacy`: accepts Shopify compliance webhooks, verifies the raw-body Shopify HMAC, persists an idempotent receipt, and invokes the tenant-scoped database operations.
- `henvalt-privacy-export`: lists and downloads customer exports for an authenticated HENVALT workspace OWNER or ADMIN. It validates the access token through Supabase Auth and checks the tenant membership in the database.
- `202611140002_shopify_privacy_request_queue.sql`: creates the service-role-only webhook receipt queue.
- `202611140003_shopify_customer_privacy_rpcs.sql`: adds tenant-scoped export, customer redaction, and shop redaction RPCs.
- `202611140004_shopify_privacy_export_storage.sql`: adds service-role-only temporary export storage and an expiry purge RPC.

## Deployment order

1. Apply migrations 002, 003, and 004 in order.
2. Deploy `henvalt-shopify-privacy` with JWT gateway verification **disabled**. It authenticates requests with Shopify's HMAC signature.
3. Deploy `henvalt-privacy-export` with JWT gateway verification **disabled** as well. It performs its own Supabase Auth user lookup and OWNER/ADMIN membership check; disabling gateway JWT is required for its browser CORS preflight to reach the function.
4. Confirm both functions are deployed and test valid/invalid HMAC, an owner export download, a customer redaction, and a shop redaction against a disposable test tenant.
5. Only then release the Shopify app version containing the three mandatory compliance topics.

Both functions use the existing Supabase project environment variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_ANON_KEY`; the webhook receiver additionally needs `SHOPIFY_API_SECRET`.

## Data handling

- Customer exports are retained in a service-role-only JSONB column for up to 30 days and are delivered as an authenticated JSON download. They are not emailed.
- Export payloads are cleared when expired. Cleanup is currently opportunistic: it runs on a verified privacy webhook and when an owner opens the privacy export page or downloads an export. A reliable scheduled purge is still required before claiming guaranteed deletion exactly at expiry.
- Unmatched shop/customer requests remain in `REVIEW_REQUIRED` instead of being silently discarded.
- Customer redaction removes linked customer, event, message, delivery, tracking, suppression, and audit/error payloads within the tenant.
- Shop redaction sanitises and detaches the receipt before deleting the tenant and its tenant-scoped records.

## Safety boundary

Do not apply these migrations, deploy either function, or release the Shopify app version until the disposable-tenant end-to-end tests pass and the merchant export delivery process is reviewed. Recovery email sending is unrelated and remains disabled.
