# Shopify privacy request atomic processing — candidate design

Date: 2026-11-22  
Status: candidate migration; not applied to production.

## Implemented in candidate SQL

- A bounded 15–300 second lease.
- Atomic single-row claim using `FOR UPDATE SKIP LOCKED`.
- A random per-claim lease token and attempt counter.
- Expired PROCESSING leases can be reclaimed.
- Completion is fenced by request ID, current PROCESSING state, matching lease token, and an unexpired lease.
- Terminal outcomes clear the raw inbound payload and customer ID.
- RPC execution is restricted to `service_role`; browser roles receive no execution grant.

## Integration still required

The currently deployed Edge Function does not call these RPCs. A future replacement must:
1. Validate HMAC over raw request bytes.
2. Parse and validate payload structure.
3. Resolve shop domain to exactly one active connection.
4. Compare the signed body shop ID with the database connection's shop ID. Do not trust the unsigned shop-ID header.
5. Persist idempotently by webhook ID.
6. Claim through the lease RPC; duplicates that cannot claim must not run side effects.
7. Run the topic-specific operation.
8. Finish using the returned lease token.
9. Return a retryable non-2xx response if persistence/processing cannot be safely completed.

## Known limitations

- This migration does not fix the deployed customer-redaction RPC's unconditional `matched: true` result.
- It does not implement Shopify's required secure customer export delivery.
- It does not change the deployed handler or workflow.
- The candidate migration needs a disposable PostgreSQL 17 execution test before review.
- Do not add Shopify `compliance_topics` until the complete request lifecycle passes isolated acceptance tests.

## Additional candidate integration added

- `claim_shopify_privacy_request_by_id` atomically claims only the exact webhook receipt inserted by the current request. This avoids the dangerous case where a generic queue claim could select an older, unrelated privacy request.
- `redact_shopify_customer_data_checked` performs tenant-scoped existence checks before calling the legacy destructive redaction routine. It can truthfully return `matched: false` without reporting a no-op as successful deletion.
- `redact_shopify_shop_data_with_lease` locks and verifies the exact PROCESSING row, token, and unexpired lease before invoking tenant deletion.
- `supabase/functions/henvalt-shopify-privacy/index.ts` is now the candidate source at the exact Supabase deployment path; the deployed v1 source is preserved byte-for-byte under `supabase/audit-baselines/henvalt-shopify-privacy-v1.ts`. The candidate verifies HMAC over raw bytes, compares signed body `shop_id` to the stored connection even after uninstall, ignores the unsigned shop-ID header as identity, stores only minimal identifiers, and returns after durable receipt persistence. The scheduled database worker claims requests and routes each topic through guarded RPCs.
- The candidate customer-data export remains in REVIEW_REQUIRED pending secure merchant delivery. It does not claim that generating an export means the merchant received it.
- Unmatched shops are queued without retaining customer ID/email. A missing or ambiguous active shop connection fails closed.

## Validation boundary

These files are candidate-only. Static Node contract tests are wired into the pull-request workflow. The new redaction wrapper migration still requires disposable PostgreSQL integration coverage against a schema containing all referenced HENVALT tables, plus Deno type-checking and end-to-end signed webhook fixtures. Do not deploy either function or apply either migration until those checks pass and the complete export-delivery lifecycle is approved.

## Retry and side-effect fencing refinement

- Failed attempts remain retryable and retain only the minimal customer ID/email needed to repeat the same operation.
- The eighth failed attempt is converted to REVIEW_REQUIRED and clears customer ID/email and the minimal payload. The generic queue claim and request-specific claim both enforce this ceiling.
- Customer redaction, customer export generation/storage, and shop deletion now have request-ID + lease-token wrappers. Each locks the receipt row and validates PROCESSING status and the unexpired lease before side effects.
- Export result persistence is performed inside the same lease-fenced database function. A no-match retry clears any prior export bundle instead of leaving stale personal data.
- Shop deletion clears lease metadata after the existing tenant-deletion routine completes.

The CI PostgreSQL acceptance now executes the lease and retention migrations against PostgreSQL 17, and executes the redaction/export wrapper migration against a disposable schema with minimal tenant-scoped table fixtures and stubbed legacy RPCs. It covers no-match behavior, matched redaction dispatch, stale-token rejection, export persistence/expiry, stale export clearing, shop-redaction completion, retry retention, attempt-eight escalation, and terminal minimization. This validates wrapper control flow but does not prove the legacy production redaction routine covers every production table; that still needs a full-schema review and integration test.

## Scheduled retention

A separate candidate migration adds `henvalt.purge_stale_shopify_privacy_request_identifiers()` and schedules it daily at 03:17 using pg_cron when the `cron` schema is already installed. It moves PENDING/FAILED/expired PROCESSING requests older than seven days to REVIEW_REQUIRED, clears customer identifiers and payload, preserves active unexpired leases, and clears expired export bundles. The routine is also executable by service_role for controlled maintenance.

The deployed project currently has pg_cron 1.6.4 installed, and its privacy request table was empty at the latest read-only check. This does not mean the candidate job is installed: the migration remains un-applied.

## Signed-body idempotency and candidate handler

Migration `202611220004_shopify_privacy_signed_payload_idempotency.sql` adds a SHA-256 digest of the exact HMAC-authenticated request bytes. The persistence RPC deduplicates on (shop domain, topic, signed-body hash), rejects reuse of an already-seen unsigned webhook ID with a different signed body, and handles concurrent insert races by re-reading the unique winner. The candidate handler stores only the signed shop ID, customer ID, request ID, and the normalized customer email required by tenant-scoped export/redaction; it does not store the raw inbound JSON or trust the unsigned shop-ID header.

Disposable PostgreSQL acceptance now checks same-ID replay, same-body/different-ID replay, conflicting body under a reused ID, and distinct-body persistence. The offline Deno check type-checks the candidate handler. These are candidate-only changes; deployed function code and production schema remain unchanged.

## Customer redaction coverage review

The deployed customer-redaction RPC was inspected read-only with `pg_get_functiondef`. Its actual mutation graph includes customer rows, canonical events, checkouts, orders, sessions, opportunities, messages, recovery interventions, tracking tokens, delivery requests/attempts, provider events, conversations, suppression rows, webhook events, processing errors, background jobs, and audit records. The candidate's no-match preflight now checks those same relationship paths before invoking that existing RPC; this prevents a request containing only an email-linked delivery record (for example) from being incorrectly classified as no-match. Disposable acceptance includes that orphaned delivery-attempt case. The production function was not changed.

## Fast webhook acknowledgement and durable worker

Shopify requires a 2xx webhook response within five seconds and recommends queuing long-running work. The candidate handler now performs HMAC verification, signed-shop validation, and durable receipt persistence, then returns 200 without running exports or multi-table redaction inline. Migration `202611220005_shopify_privacy_queue_worker.sql` adds a bounded (maximum 20, scheduled at 5) SQL worker using the atomic lease claim RPC. It handles all three compliance topics and is scheduled every minute through pg_cron when available. Failed work remains retryable through the lease state machine; export bundles remain REVIEW_REQUIRED pending secure merchant delivery.

The worker is database-native because the production project currently has pg_cron but not pg_net. This avoids adding a network extension or another n8n workflow. The migration and worker remain candidate-only until CI and full production lifecycle checks pass.

## Post-uninstall shop resolution

The OAuth uninstall handler deactivates the shop connection rather than deleting it. Shopify can send `shop/redact` after uninstall, so the candidate handler intentionally resolves the unique connection by shop domain without filtering `active=true`. The signed payload shop ID must still match the stored shop ID. The connection's inactive state must not block legal data deletion; the shop-redaction worker then uses the tenant-scoped legacy deletion RPC and sanitizes the receipt.

A legacy connection whose `shopify_shop_id` is null is not treated as a verified tenant mapping. Its HMAC-authenticated request is retained in REVIEW_REQUIRED with no tenant/customer identifiers rather than being processed against a guessed tenant.
