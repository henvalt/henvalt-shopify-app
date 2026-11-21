# HENVALT Shopify privacy compliance operations V2

**Status:** operational requirements and launch-gate documentation. This is not legal advice and does not authorize a retention or deletion policy. Branch-only; no live systems changed.

## Shopify's published requirements

Source of truth: [Shopify — Privacy law compliance](https://shopify.dev/docs/apps/build/compliance/privacy-law-compliance) (checked 17 November 2026).

- Public App Store apps must subscribe to and handle all three compliance topics: `customers/data_request`, `customers/redact`, and `shop/redact`.
- Endpoints must accept POST JSON requests. An invalid Shopify HMAC must receive HTTP 401.
- A successful receipt must be acknowledged with a 2xx response. The requested action must be completed within 30 days of receiving the request. Shopify says not to complete a redaction when data must be retained for a legal obligation.
- Shopify sends `customers/redact` five days after the deletion request; it can defer the webhook when a scheduled gift card has not yet been delivered.
- Shopify sends `shop/redact` 48 hours after app uninstall. This is a store-data erasure request, not merely an uninstall notification.

These timings describe Shopify's webhook/request lifecycle. They do not replace the merchant's or app operator's legal assessment of what must be retained.

## Payload fields that must not be silently discarded

Shopify's documented examples include:

- `customers/data_request`: `shop_id`, `shop_domain`, `customer.id`, `data_request.id`, and `orders_requested[]`.
- `customers/redact`: `shop_id`, `shop_domain`, `customer.id`, and `orders_to_redact[]`.
- `shop/redact`: `shop_id` and `shop_domain`.

Shopify notes that some customer records may contain only an email address. HENVALT's current V2 receipt stores no raw email, and its queue requires a customer ID for customer-scoped jobs. Therefore an email-only request must remain in manual review until a privacy-safe, exact-store resolution path exists. Never persist raw email just to make the queue claimable.

The current V2 receipt schema records the exact connection, app, shop, topic, webhook ID, customer ID (when supplied), data-request ID (when supplied), and body digest. It does **not** persist `orders_requested[]` or `orders_to_redact[]`. The current export draft gathers exact-store customer-linked V2 rows, while the redaction preview counts the full exact-store customer graph. Before a processor is approved, add explicit handling for Shopify's order-ID arrays and prove that it neither omits required data nor expands a redaction beyond the verified request's scope.

## HENVALT's current safe behavior

1. Verify raw-body HMAC using the app-specific secret and validate the exact app + shop + stored Shopify shop ID.
2. Store a minimal receipt with immutable connection lineage and an idempotent webhook identity. Do not store the raw body or customer email.
3. Return 2xx only after the verified receipt is durably stored. The response means **received**, not exported, deleted, or completed.
4. Keep missing/conflicting identity, email-only customer requests, and incomplete payloads in review. Never fall back to tenant-wide legacy export or deletion.
5. Claim work only through the service-role queue, with a short lease and one-time claim token.
6. Treat the existing export builder as a draft only. It explicitly excludes unresolved legacy tenant-scoped rows and returns `completion_eligible=false`.
7. Treat the existing customer-redaction preview as read-only. It returns `safe_to_execute=false`; it does not delete, anonymize, or complete a request.
8. Treat the exact-store `shop/redact` stop trigger as a stop boundary only. It disables the matched connection and prevents new work; it does not erase the store's historical data.
9. Complete a request only after an independently verified export delivery or a fully verified, policy-approved redaction. A generated export JSON document, queue claim, stop trigger, HTTP 200, or operator assertion alone is not completion.

## Launch blockers and operational controls

- **No production processor exists.** The deployed privacy handler remains receipt-only; the branch contains a queue, an export draft, and read-only redaction preview. Do not describe privacy compliance as end-to-end complete.
- Implement a durable deadline monitor using `received_at + interval '30 days'`, with alerts well before the deadline, an owner, escalation, and a manual-review queue. The current queue's ten-attempt cap is not a compliance deadline monitor.
- Preserve Shopify's `orders_requested[]` and `orders_to_redact[]` semantics in the verified receipt or a separately protected, minimal child record. Validate numeric Shopify IDs and bind them to the same immutable connection.
- Design a secure export delivery channel to the merchant. Do not return customer data from the webhook ingress, expose it to a browser, or place it in logs.
- Resolve historical tenant-scoped records only when independent immutable provenance exists. Null-lineage rows remain unresolved; never infer their store from email, reused Shopify IDs, or JSON metadata.
- Approve a field-level retention policy before customer or shop redaction. Preserve only what is demonstrably required; do not delete cost, provider, refund, attribution, or fee audit records without a reviewed detachment/anonymization design.
- Test duplicate delivery, changed-body replay, two stores sharing customer/order IDs, missing customer ID, email-only requests, expired claims, retry exhaustion, partial failure, delivery confirmation, and exact-store isolation.
- Monitor all compliance receipts by topic and age, including `REVIEW_REQUIRED`, `FAILED`, and claimed jobs nearing lease/deadline expiry. An unlinked request must remain visible and escalated, not silently dropped.

## Release gate

Do not submit or release the public app until the three compliance topics are configured on the Partner-owned app, bad HMAC behavior is verified, the secure export path works, exact-store customer/shop redaction is implemented and tested, unresolved legacy records have a documented disposition, and the 30-day operational process is staffed. No production rollout is authorized by this document.


## Verified order-scope preservation (candidate migration 021)

The candidate migration `202611170021_shopify_privacy_order_scope_v2.sql` adds a service-role-only child table keyed by the verified privacy receipt. It stores `orders_requested[]` as `REQUESTED` and `orders_to_redact[]` as `TO_REDACT`, preserving array order and numeric Shopify IDs while rejecting malformed, duplicate, zero, negative, oversized, or over-limit arrays. The receipt's body digest remains the idempotency evidence; repeated identical deliveries do not create duplicate order rows, and changed-body reuse remains rejected.

This is scope preservation only. It does not yet prove that HENVALT owns every requested order record, does not fetch or export Shopify order data, does not execute deletion, and does not authorize completion. Exact-store processors must separately verify each requested order against the same immutable connection before acting. Email-only customer requests remain review-only.


## Exact-store order scope reporting (candidate migration 022)

Candidate migration `202611170022_shopify_privacy_order_scope_report_v2.sql` now surfaces the preserved order IDs in both the customer export draft and the read-only redaction impact preview. It reports requested IDs, exact-store/customer identity matches, and unmatched IDs separately. A match means only that HENVALT has an order-identity row for the same tenant, immutable Shopify connection, order ID, and customer identity.

**An identity match is not a complete Shopify order export.** HENVALT's current order projection stores summary fields, not full line items or every Shopify order/customer field. The report therefore explicitly returns `export_data_complete=false` and `requires_manual_review=true`. Neither the export draft nor redaction preview can complete a request, deliver data, or delete/anonymize records.


## Deadline monitor view (candidate migration 023)

Candidate migration `202611170023_shopify_privacy_deadline_monitor_v2.sql` adds a service-role-only read view over privacy receipts and queue state. It computes the 30-day deadline, remaining time, exact-store binding status, customer-scope completeness, claim lease state, retry exhaustion, and an attention flag. It distinguishes completed, overdue, identity-review, missing-queue, failed, expired-lease, and near-deadline work.

This is monitoring data only. It does not schedule itself, send alerts, assign an operator, retry a job, or complete a request. A production operational owner, alert delivery, escalation, and deadline response process remain launch requirements.
