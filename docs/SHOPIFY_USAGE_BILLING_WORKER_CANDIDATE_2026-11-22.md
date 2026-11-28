# Shopify usage billing worker candidate — 2026-11-22

## Why this candidate exists

The read-only production audit found billing claim/result RPCs and authenticated control-plane routes, but no billing usage worker in the three active n8n workflows and no active billing usage cron job. The database can create a durable usage-charge claim, but that alone does not submit a Shopify usage record.

This candidate adds a separately testable Supabase Edge Function handler. It is deliberately not deployed or scheduled.

## Execution contract

1. Deploy the function with Supabase JWT verification disabled only because the handler enforces its own dedicated bearer secret; do not expose the endpoint without `HENVALT_BILLING_WORKER_TOKEN` configured.
2. An internal caller POSTs `{"shop":"<shop>.myshopify.com"}` with the dedicated `HENVALT_BILLING_WORKER_TOKEN`.
3. The handler obtains the shop's offline Shopify token through the service-role-only `get_shopify_access_token_for_control_plane` RPC.
4. It calls `control_plane_claim_billing_usage` once. No eligible measurement is a successful no-op.
5. It validates the durable charge envelope and submits Shopify's `appUsageRecordCreate` mutation with the database-persisted `idempotencyKey`.
6. A confirmed provider record ID is persisted through `control_plane_record_billing_usage_result`.

## Ambiguous outcomes are not failures

A network exception, HTTP 429/5xx, malformed response, top-level GraphQL error, incomplete mutation payload, or Shopify idempotency-concurrency response is treated as **PENDING / outcome unknown**. The worker does not call the result RPC in these cases. The next attempt must reuse the exact same persisted charge amount, line item, currency and idempotency key.

This matters because Shopify can accept a usage charge while the response is lost. Marking that charge FAILED and generating a new idempotency key would risk a duplicate charge. Shopify's `appUsageRecordCreate` accepts `idempotencyKey` (maximum 255 characters); HENVALT's key is stored before the provider call and reused on retry.

Explicit HTTP rejections and explicit mutation `userErrors` are recorded as FAILED. A successful provider record whose local result commit fails remains PENDING; the retry uses the same Shopify key and can safely recover the original provider result.

## Credit and refund behavior

The candidate depends on migration `202611220011_billing_refund_credit_offsets.sql` for tenant/currency-scoped credit allocation. Existing PENDING/FAILED charge retries preserve their original net amount; newly arrived credits do not rewrite an already-created charge. Credits apply to later eligible positive measurements. This is a deliberate accounting policy, not a retroactive adjustment of an already-submitted Shopify usage record.

## Required before any activation

- Apply and validate the migration set in an isolated Supabase staging project with production-equivalent roles, functions, Vault secrets and constraints.
- Add the worker to the existing `HENVALT_RECOVERY` scheduler path (do not add a fourth workflow), with a bounded per-run claim count and a dedicated service secret.
- Prove one successful synthetic Shopify usage record in a Shopify development store and reconcile its provider record ID to HENVALT's charge, measurement and ledger.
- Prove timeout-after-provider-acceptance retries with the same idempotency key and no duplicate Shopify usage record.
- Prove refund credits across partial, full, exhausted and concurrent allocations; verify behavior when credits arrive after a charge is PENDING or SUBMITTED.
- Add an operator path for charges that exhaust retries or remain PENDING beyond the idempotency retention window.

## Safety boundary

This repository change is candidate code only. It does not deploy the Edge Function, create secrets, modify the live cron schedule, change n8n, create a real usage charge, or alter production data. The production project remains untouched.
