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
- `supabase/functions/henvalt-shopify-privacy-candidate/index.ts` is a separate, non-deployed handler candidate. It verifies HMAC over raw bytes, compares signed body `shop_id` to the active connection, ignores the unsigned shop-ID header, stores only minimal identifiers, claims the exact receipt, and routes each topic through the guarded RPCs.
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

These refinements still require disposable PostgreSQL execution tests. The current CI acceptance covers claim serialization, request-specific claim, retry retention, attempt-eight escalation, and terminal minimization. It does not yet execute the new wrappers against a full disposable copy of the HENVALT schema.
