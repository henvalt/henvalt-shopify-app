# HENVALT billing worker — recovery scheduler integration candidate

Status: candidate-only. This specification and graph builder do not edit, publish, execute, or activate the connected n8n workflow.

## Architecture

The billing worker is scheduled from the existing `HENVALT_RECOVERY` workflow's `Every Minute` trigger. It does not create a fourth workflow and does not change `HENVALT_INGEST` or `HENVALT_DELIVERY`.

Candidate branch:

1. `Find Shopify Usage Billing Shops` selects up to ten active shops with an active usage line item and a confirmed, billable, positive recovery-fee measurement that is new or retry-due.
2. `Call Shopify Usage Billing Worker` sends only the shop domain to the dedicated Edge Function. The worker itself claims exactly one charge through `control_plane_claim_billing_usage`, allocates refund credits transactionally, calls Shopify's `appUsageRecordCreate` with the persisted idempotency key, and records a confirmed result.
3. The worker HTTP node is terminal. No email/delivery node is called by this billing branch.

The discovery query also requires `billing_accounts.test_mode = true`. The candidate claim RPC independently rejects every non-test subscription with `TEST_MODE_REQUIRED`; the worker therefore cannot create a live merchant charge through this candidate migration. Enabling live billing must be a separate reviewed migration and cutover.

The discovery query is deliberately read-only. It does not allocate credits, create usage charges, or change billing state. The claim RPC remains the sole authority for charge creation and refund-credit allocation. The query mirrors the worker's retry windows so the scheduler does not repeatedly call shops whose charges are not yet due.

## Credential and endpoint gate

The generated candidate uses `https://supabase-staging.invalid/functions/v1/henvalt-shopify-usage-billing` and contains no credential material. Before isolated staging execution only:

- Replace the invalid host with the isolated staging project's function URL.
- Create a dedicated n8n Header Auth credential with `Authorization: Bearer <staging worker token>`.
- Store the same staging token as `HENVALT_BILLING_WORKER_TOKEN` in the staging Edge Function secrets.
- Deploy the staging Edge Function with `verify_jwt=false`; the handler performs constant-time bearer-token validation itself. Do not use the production service-role key as the worker token.
- Use a Shopify development store and a test-mode usage subscription. Add a provider stub/network-egress gate for timeout-after-acceptance and manual-reconciliation tests before allowing Shopify GraphQL egress.

The candidate does not set a real URL, credential ID, token, or production project reference.

## Retry and timeout behavior

- The SQL discovery branch returns at most ten shops per scheduler tick.
- The claim RPC serializes charge claims and reuses the original Shopify idempotency key for a retry.
- The HTTP node does not enable blind node-level retries. Ambiguous transport outcomes stay PENDING in the database and are retried only through the worker's persisted attempt/backoff rules.
- The worker's 202 response indicates an ambiguous pending outcome, not a successful charge.
- Exhausted ambiguous attempts require operator reconciliation; they must not be rewritten to FAILED solely because the client timed out.

## Release boundary

No live n8n workflow was modified or published. No Edge Function was deployed. No SQL migration was applied. No Shopify usage record or email was created. The candidate graph remains inactive, has no credentials, and targets an invalid staging hostname.

Remaining staging acceptance: full-schema migration replay, development-store billing approval, normal charge, refund-credit offsets, duplicate claim race, timeout after Shopify acceptance, and operator reconciliation.
