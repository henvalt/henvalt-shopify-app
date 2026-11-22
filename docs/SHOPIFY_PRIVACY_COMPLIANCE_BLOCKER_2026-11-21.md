# Shopify App Store privacy-compliance blocker — 2026-11-21

**Decision: NO-GO for public App Store distribution until all three mandatory compliance topics are configured and the receiving path is proven end to end.** This is a candidate-branch audit only. No production app configuration, webhook subscription, Worker, Edge Function, database or workflow was changed.

## Shopify requirement

Shopify requires every App Store-distributed app to subscribe to all three compliance topics, even if it does not store customer personal data:

- `customers/data_request` — provide the requested customer data to the merchant.
- `customers/redact` — erase/anonymize the requested customer's personal data.
- `shop/redact` — erase the shop's data after uninstall.

Shopify requires these subscriptions to be declared in the app configuration TOML using `compliance_topics`; they are not part of the ordinary per-shop GraphQL `webhookSubscriptionCreate` loop. See:
- https://shopify.dev/docs/apps/build/compliance/privacy-law-compliance
- https://shopify.dev/docs/api/webhooks/2026-10
- https://shopify.dev/docs/apps/build/security/app-security-checks/missing-compliance-webhooks

## Current HENVALT evidence

### App configuration

The candidate `shopify.app.toml` now contains one `[[webhooks.subscriptions]]` entry declaring all three `compliance_topics` against the existing Supabase privacy endpoint. The OAuth code's immutable operational webhook list contains 12 business topics and no compliance topics; that is correct because mandatory compliance topics belong in TOML, not the per-shop GraphQL registration loop. The configuration is not deployed.

### Receiving path

The current Cloudflare ingress accepts any signed Shopify topic and forwards it to the active `HENVALT_INGEST` endpoint. The active ingest graph and its sanitized candidate fixture have no dedicated compliance-request branch. A valid HMAC and HTTP 200 from the generic ingress do not prove a privacy request was durably handled.

### Database

Read-only production catalog inspection found `henvalt.shopify_privacy_requests` with 0 rows and the following relevant capabilities:
- Service role can insert, select and update the queue; client roles have no direct grants and the table has no RLS policies.
- `henvalt.redact_shopify_customer_data(uuid,text,text)` exists and is service-role-only. It performs tenant-scoped customer data deletion/anonymization, but does not itself enqueue or claim a Shopify privacy request.
- `henvalt.redact_shopify_shop_data(uuid)` exists and is service-role-only. It consumes a queued `shop/redact` request and deletes the tenant after sanitizing the queue receipt.
- `henvalt.purge_expired_shopify_privacy_exports()` exists.
- The production pg_cron catalog shows the export-purge job active every 15 minutes. This only proves expiry cleanup is scheduled; it does not implement the missing request ingestion or customer-data export.
- Correction from the 2026-11-21 Edge Function inspection: an active `henvalt-shopify-privacy` production Edge Function exists (version 1, `verify_jwt=false`). It receives the three compliance topics, verifies HMAC over the raw request body, inserts into `shopify_privacy_requests`, and calls export/redaction RPCs synchronously. It is not yet a proven end-to-end compliance implementation: the data export awaits secure merchant delivery, the queue is not atomically claimed, and the deployed v1 source has now been captured as an immutable audit baseline while a hardened replacement is staged at the exact Supabase function deployment path.

The presence of a queue table and isolated redaction functions is not evidence that Shopify's incoming compliance webhooks are accepted, acknowledged, completed or retried correctly.

## Required implementation before deploying the TOML subscriptions

1. Preserve the deployed `henvalt-shopify-privacy` v1 source as an immutable audit baseline (done) and stage the hardened replacement at `supabase/functions/henvalt-shopify-privacy/index.ts` (candidate only). The replacement verifies HMAC over exact raw bytes, compares the signed payload `shop_id` with the stored shop connection, and never trusts the unsigned `x-shopify-shop-id` header as identity.
2. Replace read-then-process queue handling with an atomic claim/lease transition. Candidate migration `202611220001` adds fenced leases; `202611220004` binds replay identity to the signed payload hash; and `202611220005` adds a bounded scheduled worker. These are not production-applied.
3. Complete `customers/data_request`: the current handler calls `export_shopify_customer_data` and stores a 30-day result, but marks it `REVIEW_REQUIRED` with `export_ready_for_secure_merchant_delivery`; no secure merchant delivery is performed in the inspected handler. Implement and test that controlled, auditable delivery.
4. Harden `customers/redact`: candidate migration `202611220002` adds a tenant-scoped preflight across the deployed redaction graph and returns a true no-match result before calling the legacy destructive RPC. Disposable PostgreSQL acceptance covers matched and unmatched requests, including email-linked delivery attempts. The legacy production RPC is unchanged.
5. Verify `shop/redact`: the current handler invokes the tenant deletion RPC. Prove shop identity binding, tenant-wide send/processing stop, deletion scope, backups, provider logs and n8n execution-data treatment in isolated staging.
6. Candidate migration `202611220005` adds a lease-bound worker with bounded batches, retry/dead-letter handling and service-role-only execution. It runs in PostgreSQL rather than n8n, avoiding raw privacy payloads in n8n execution history. The cron schedule is tested in a disposable fixture and is not production-installed.
7. Test duplicates, invalid HMAC, unknown shops, service/database outage, partial failure, retry, customer-id-only and email-only payloads, completed replay, legal-hold exceptions, and full shop deletion in isolated staging.
8. The candidate `shopify.app.toml` now declares all three `compliance_topics` against the existing Supabase privacy endpoint. Before deploying that configuration, deploy the candidate privacy handler and durable queue worker, verify the endpoint end-to-end, then validate the actual Shopify app configuration. Do not point production compliance subscriptions at an implementation that has not passed the lifecycle tests.

## Explicit release gate

- [ ] All three compliance topics deployed in the Shopify app configuration (candidate TOML declaration exists; production configuration is unchanged).
- [ ] The configured URI resolves to the intended production endpoint with valid TLS.
- [ ] Each topic reaches a dedicated handler and is durably accepted before 2xx.
- [ ] Customer data request export is implemented and tested.
- [ ] Customer redaction is implemented and tested.
- [ ] Shop redaction is implemented and tested, including tenant-wide stop and deletion.
- [ ] Retry, idempotency, audit, backup and execution-retention behavior is documented.
- [ ] Isolated end-to-end acceptance evidence exists.
- [ ] Shopify app configuration validation and App Store security checks pass.

**Current status: PARTIALLY IMPLEMENTED / SOURCE CONFIGURED / PRODUCTION NO-GO.** The candidate TOML declares the mandatory topics, and a hardened handler plus lease-backed queue worker are staged and under CI. Critical export delivery and full lifecycle staging remain unproven. Keep production app configuration and deployments unchanged.

## Additional production catalog evidence — 2026-11-21 (second read-only catalog pass)

A second read-only catalog pass inspected the exact privacy queue columns, constraints, grants and full definitions of the three existing privacy functions.

### Queue and retention findings

- `shopify_privacy_requests.payload` is a required `jsonb` column. The row also stores `shop_domain`, `shopify_shop_id`, `customer_id`, `request_id`, `topic` and `webhook_id`.
- The unique idempotency constraint is on `webhook_id`; `request_id` is nullable.
- The queue's allowed states are `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED` and `REVIEW_REQUIRED`.
- Service role has INSERT/SELECT/UPDATE on the queue; the table has no client-role grants. The tenant foreign key uses `ON DELETE SET NULL`.
- The 15-minute purge function clears only expired `result_payload` and `result_expires_at`. It does not purge or sanitize the required inbound `payload`.

### Newly confirmed customer-redaction gap

The current `redact_shopify_customer_data(p_tenant_id, p_shopify_customer_id, p_customer_email)` function performs broad tenant-scoped redaction across customer, event, checkout, order, session, message, delivery, provider-event, webhook, processing-error, background-job, opportunity and audit data. However, its inspected definition does **not** update `shopify_privacy_requests`. Therefore the original `customers/redact` webhook payload (including customer identifiers and potentially email) can remain in the privacy queue after the customer redaction function completes. The separate `shop/redact` function does sanitize its own queue receipt before deleting the tenant; that behavior does not cover customer-redact requests.

This is a distinct privacy-retention defect, not just the missing webhook receiver. A future handler must sanitize the completed customer-request queue payload while retaining only the minimum non-identifying idempotency/audit receipt required for replay safety. It must also define safe treatment of `FAILED` and `REVIEW_REQUIRED` payloads, including bounded retention and operator review without indefinite raw PII storage.

### Release-gate consequence

Do not describe the existing customer-redaction RPC as end-to-end Shopify compliance. The function is a useful tenant-scoped primitive, but request ingestion, request lifecycle, durable worker orchestration, customer-data export, and post-redaction queue sanitization are still incomplete. Do not deploy the candidate `compliance_topics` declaration until the hardened handler, durable worker, and end-to-end lifecycle have been verified in an isolated environment.


## Correction and additional live evidence — 2026-11-21 (production function read-only inspection)

The earlier statement that no privacy webhook handler exists was too broad. A read-only Supabase function inventory found an **ACTIVE** production Edge Function:

- Slug: `henvalt-shopify-privacy`
- Version: `1`
- JWT verification: disabled (appropriate only because the function performs Shopify HMAC verification itself)
- Deployed source SHA-256: `213af659378fd3da90b8edbfce12347445e4f5ce633ca6bf6705f8d3cae3e5f4`
- The function is not present in the current Git branch tree, creating a source-control/reproducibility gap.

### What the deployed v1 actually does

- Accepts `customers/data_request`, `customers/redact` and `shop/redact`.
- Verifies HMAC-SHA256 against the exact raw request body before parsing JSON.
- Resolves a tenant by `shop_domain`, inserts a privacy queue row with unique `webhook_id`, and invokes export/customer-redaction/shop-redaction RPCs.
- For data requests, generates a result and stores it with a 30-day expiry, but leaves the request in `REVIEW_REQUIRED` with `export_ready_for_secure_merchant_delivery`. The inspected handler does not deliver that export to the merchant.
- For customer redaction, calls `redact_shopify_customer_data`, then clears the queue payload only if the RPC reports success.
- For shop redaction, calls `redact_shopify_shop_data`, which sanitizes its queue receipt before tenant deletion.

### Confirmed gaps in v1

1. **Shop identity binding:** the function resolves by the shop-domain header and stores the unsigned shop-ID header, but does not compare the HMAC-covered payload `shop_id` with the resolved connection's `shopify_shop_id`. The shop-ID header itself is not covered by the body HMAC.
2. **No atomic claim/lease:** after idempotent insert, the function reads the row and processes it without first transitioning `PENDING` to `PROCESSING` under an atomic lock/lease. Concurrent duplicate deliveries can race.
3. **Customer no-match detection is ineffective:** the current `redact_shopify_customer_data` SQL function returns `matched: true` unconditionally after its tenant-scoped operations, including when it found no customer row. The handler's `if (!result?.matched)` review branch therefore cannot detect this case.
4. **PII retention on unresolved states:** `FAILED` and `REVIEW_REQUIRED` customer requests can retain the original inbound payload and customer ID. The 15-minute purge only clears expired `result_payload` and does not sanitize inbound `payload`.
5. **Export delivery incomplete:** generated customer export data is stored for 30 days but remains awaiting secure merchant delivery. No delivery implementation was found in this function.
6. **Source drift:** the deployed function is not tracked in the current Git tree, so the repository cannot reproduce or reliably test the live implementation.

### GitHub workflow safety finding

The prior `.github/workflows/controlled-privacy-hmac-test.yml` was manually triggerable and used the repository `SHOPIFY_API_SECRET` to POST a synthetic `customers/data_request` directly to the production Supabase function URL. This was not a staging test. The candidate branch now replaces that workflow with offline-only HMAC fixtures and a static guard test. **This candidate change does not alter the default branch**; the production-calling workflow remains on the default branch until a reviewed merge or an explicitly authorized workflow-disable action.

The candidate branch's offline workflow is guarded by:
- `tests/shopify-privacy-hmac-contract.test.mjs`
- `tests/shopify-privacy-workflow-safety.test.mjs`

No production function, workflow, secret, database row, app configuration or deployment was changed during this inspection.


## Additional deployed export endpoint inspection — 2026-11-21 (read-only)

A separate ACTIVE Supabase Edge Function was found and captured in the candidate source tree:

- Slug: `henvalt-privacy-export`
- Version: `1`
- JWT verification: disabled at the gateway; the function independently validates the bearer token against Supabase Auth.
- Deployed source SHA-256: `708f0d953874f9e4896f433d950d57b823b56cbb33e30e8c0b1f966ec1212d97`
- Candidate baseline: `supabase/functions/henvalt-privacy-export/index.ts`

### What this endpoint adds

- Requires a valid Supabase user session.
- Requires exactly one OWNER/ADMIN tenant membership.
- Lists up to 50 customer data-request rows for that tenant.
- Allows download of a non-expired `result_payload` for a tenant-scoped privacy-request UUID.
- Sets `result_delivered_at` before returning the JSON attachment.

### Remaining concerns

- This is a merchant-owner pull/download endpoint, not automatic delivery to Shopify or the customer. It narrows the gap but does not prove that the data subject received the export.
- `result_delivered_at` is set before the response body has been confirmed received, so it records a download attempt/response initiation rather than verified receipt.
- The export request remains `REVIEW_REQUIRED` after the download timestamp is set; no terminal completion transition is made by this endpoint.
- The URL parameter named `request_id` is actually matched against the internal queue row UUID (`id`), not Shopify's external `request_id`; the naming should be clarified.
- CORS allows any origin, although the endpoint still requires a bearer token validated by Supabase Auth and an owner/admin membership. Review this against the dashboard's actual deployment origins.
- The endpoint's independent authentication is a positive control; do not turn on gateway JWT verification without validating the dashboard's token forwarding and deployment behavior.

The deployed `henvalt-shopify-privacy` v1 source is preserved byte-for-byte at `supabase/audit-baselines/henvalt-shopify-privacy-v1.ts` as an **AUDIT BASELINE ONLY**. The deployed `henvalt-privacy-export` v1 source remains at `supabase/functions/henvalt-privacy-export/index.ts` as an **AUDIT BASELINE ONLY**. Their source hashes are pinned in-file. The hardened privacy replacement is staged at the exact deployable path `supabase/functions/henvalt-shopify-privacy/index.ts`. Production remains unchanged.


### Latest queue-state and privilege verification — 2026-11-21 (read-only)

- The production `shopify_privacy_requests` table had **zero rows** at this inspection. There are no currently queued privacy requests to remediate or manually deliver.
- `service_role` has only the table privileges needed by the handler (INSERT, SELECT, UPDATE); no anon/authenticated grants were present in the inspected grants.
- The queue has a unique constraint on `webhook_id`, an allowed-status check, and topic allowlist check.
- Existing indexes cover export expiry, pending/review/failed state scans, shop/status scans and webhook idempotency. The candidate tenant FK index is still not production-applied.
- The deployed `purge_expired_shopify_privacy_exports()` function only nulls expired `result_payload` and `result_expires_at`; it does not clear inbound `payload`, `customer_id`, or `last_error`.
- The queue state count query returned no rows, consistent with the empty table.

### Candidate CI evidence for baseline capture

The two audit-baseline files, documentation, and static regression test were added to the candidate branch. The offline contract workflow passed (run 44937879940) and the full safety/pixel-consent workflow passed (run 44937880000) on candidate commit `cb686659d1c3b1678b264a23db6a4c2785e419f7`. These are code/fixture checks only; they do not exercise production webhooks or prove the live privacy flow is compliant.


## 2026-11-22 candidate update

The candidate `shopify.app.toml` now declares `customers/data_request`, `customers/redact`, and `shop/redact` under `[[webhooks.subscriptions]]`, using the existing Supabase privacy endpoint. This removes the configuration omission from the source tree, but does not complete the production compliance gate: the endpoint still runs the previously deployed implementation. The candidate handler, queue worker migration, and cron schedule must be deployed and verified before running `shopify app deploy`. No app configuration deployment or Shopify release was performed.
