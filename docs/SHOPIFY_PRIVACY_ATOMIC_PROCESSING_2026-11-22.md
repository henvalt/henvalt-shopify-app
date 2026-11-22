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
