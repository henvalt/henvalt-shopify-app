# HENVALT exact-store privacy lifecycle V2

**Status:** design gate only; no export, deletion, redaction or uninstall processor is implemented by this document. All work remains branch-only. The verified privacy webhook inbox currently records requests as `REVIEW_REQUIRED`.

## 1. Non-negotiable scope

- Resolve every request from the verified privacy receipt's immutable `connection_id`, `app_key` and `tenant_id`; never route by shop-domain text alone after receipt.
- A customer request applies to that exact Shopify customer ID in that exact connection. A shop-redact request applies to that exact connection, not the tenant or its other stores.
- Rows with `shopify_connection_id IS NULL`, missing connection lineage, or ambiguous legacy provenance are unresolved. Do not infer ownership from email, matching IDs across stores, checkout token, or JSON metadata.
- A 200 from the privacy ingress currently means only that a verified receipt was durably recorded. It does not mean export or deletion completed.
- Uninstall must immediately stop new processing and delivery for that connection; it is not a substitute for the separate privacy redaction request.

## 2. Exact-store data inventory

| Area | V2 records | Customer-linked fields / dependencies |
|---|---|---|
| Identity | `shopify_customer_identity_v2` | `external_customer_reference` is the Shopify customer ID; root customer identity |
| Sessions | `shopify_session_identity_v2`, `shopify_session_alias_identity_v2` | Session has nullable customer FK; aliases cascade from exact-store session |
| Storefront events | `shopify_pixel_event_inbox_v2` | Exact connection plus customer/client/checkout references and consent-filtered payload |
| Checkout/order | `shopify_checkout_identity_v2`, `shopify_order_identity_v2` | Customer FK is nullable on delete; checkout token, order/checkout IDs and financial facts need an explicit retention rule |
| Recovery | `shopify_checkout_recovery_candidate_v2`, `shopify_recovery_opportunity_v2` | Candidate references checkout and source receipt; opportunity references candidate, checkout, source receipt and nullable customer |
| Consent | `shopify_customer_email_consent_v2` | Exact-store customer consent evidence; delete or retain only under an explicit lawful-evidence policy |
| Delivery | `shopify_recovery_intervention_v2`, `shopify_delivery_permits_v2`, `shopify_recovery_send_attempt_v2` | Intervention and attempt currently require customer identity; permits store a keyed recipient fingerprint |
| Suppression/provider | `shopify_delivery_suppressions_v2`, `shopify_mailer_provider_events_v2` | Suppression stores a keyed recipient fingerprint and restrictive references to customer, attempt and provider event |
| Cost ledger | `shopify_delivery_cost_reservations_v2` | Merchant cost amount/currency is useful accounting data but currently references a send attempt with a restrictive FK |
| Compliance receipt | `shopify_privacy_webhook_deliveries` | Stores exact connection, customer ID, request ID and body digest; customer ID must be cleared after processing where retention permits |
| Legacy core | `customers`, `sessions`, `session_aliases`, `checkouts`, `canonical_events` | May contain direct email or customer references; only rows with proven exact connection lineage can be processed automatically |

## 3. Referential-integrity implications

The current V2 foreign keys deliberately prevent naive deletion:

1. Session aliases cascade from their exact-store session; sessions set their customer reference to NULL when the customer identity is deleted.
2. Checkout and order identities set their customer reference to NULL, but checkout tokens, IDs and financial facts remain and need an explicit policy.
3. Candidates restrict checkout and source-receipt deletion. Opportunities restrict candidate, checkout and source-receipt deletion; their customer reference is nullable.
4. Interventions and send attempts currently require customer identity and have restrictive references. Provider events and suppressions also restrict deletion of their source attempts/events.
5. Delivery permits reference the customer, intervention, sender, provider and optional send attempt. They should be deleted before their parent delivery graph.
6. Cost reservations restrict send-attempt deletion. Removing attempts without an accounting-preserving anonymization change would also remove or strand cost history.
7. The privacy receipt is a durable compliance audit row and should normally remain, but its raw Shopify customer ID must not remain indefinitely after successful processing.

Therefore a customer delete cannot safely be implemented as a single `DELETE FROM shopify_customer_identity_v2`. The schema needs a deliberate anonymization/retention migration before a processor can execute.

## 4. Proposed request behavior

### `customers/data_request`

- Claim the receipt idempotently with a short processing lease.
- Resolve exact connection and customer identity using the verified receipt's customer ID and exact connection.
- Build an export from exact-store V2 rows plus legacy rows whose connection lineage is proven.
- Exclude other stores in the same tenant and all unresolved legacy rows; record their count and route them to manual review rather than silently including or deleting them.
- Deliver the export through a secure, Shopify-compliant response path; do not return customer data to the webhook caller or browser.
- Mark COMPLETED only after export delivery is confirmed. A durable internal export artifact alone is not completion.

### `customers/redact`

- Claim and process only the exact customer ID + exact connection.
- Remove direct identifiers and customer-linked event/session/checkout data for that connection.
- Delete delivery permits and transient recipient-resolution material.
- Retain a recipient fingerprint suppression only if the merchant's lawful retention basis and Shopify policy permit it; otherwise remove it. If retained, detach it from the customer identity and preserve only the minimum keyed fingerprint needed to honor unsubscribe/spam/hard-bounce state.
- Preserve cost/accounting facts only after schema changes detach them from the customer and send-attempt identity. Do not silently delete financial usage rows.
- Clear the customer ID from the privacy receipt after processing, retain the body digest, topic, request ID, exact connection, timestamps and outcome.
- Mark COMPLETED only after all exact-store processors succeed; partial work remains retryable and auditable.

### `shop/redact`

- Stop processing for the exact connection, revoke its route token(s), and disable its delivery path.
- Delete exact-store identity, session, pixel, checkout, candidate, opportunity, intervention, permit and customer-linked delivery data in a dependency-aware order.
- Retain only minimum non-personal merchant billing/accounting aggregates if legally permitted.
- Do not delete tenant billing, provider configuration, or any other store's data merely because the shop shares a tenant.
- Keep the compliance receipt as a minimal audit record with no customer ID.

### `app/uninstalled`

- Immediately mark only the matching connection inactive, revoke its webhook route token(s), stop new recovery work, and cancel pending permits.
- Keep historical data until the corresponding privacy redaction request is processed; do not equate uninstall with a verified `shop/redact`.
- A connection with missing or ambiguous app identity must fail closed and be reviewed.

## 5. Required schema changes before implementation

- Add a server-only privacy processing ledger/lease keyed by the verified receipt ID, with bounded retries, idempotent completion and explicit failure codes.
- Define a retention contract for order identifiers, checkout tokens, consent evidence, send attempts, provider event IDs, keyed suppression fingerprints and monetary reservations.
- If suppression fingerprints are retained, make the customer FK nullable and detach source-attempt/event references safely; preserve exact-store scope and uniqueness semantics.
- Make customer references in retained audit/attempt rows nullable or replace them with non-reversible, purpose-limited tombstones. Do not weaken composite exact-store constraints.
- Make cost reservations independently retainable from a send attempt (nullable attempt reference or a separate immutable accounting key) before customer-linked attempts can be removed.
- Add explicit scrub/delete operations for exact-store legacy `customers`, `checkouts`, `canonical_events` and pixel inbox data. Null-lineage legacy rows remain unresolved.
- Keep all processor functions SECURITY DEFINER with empty/fixed search_path, service-role-only execution, exact connection predicates, bounded batches and audit logging.

## 6. Acceptance tests

1. A customer-redact request for Store A deletes/anonymizes only that customer in Store A; Store B's same Shopify customer ID remains untouched.
2. A request with a valid HMAC but unknown app/store connection is durably review-gated and cannot fall back to tenant-wide deletion.
3. Duplicate webhook IDs are idempotent; same ID with changed body digest is rejected.
4. A null-lineage legacy customer/checkout/event is not deleted by a guessed store mapping.
5. Session aliases and exact-store dependent rows are removed in the intended order without violating FKs.
6. Suppression fingerprints survive only under the approved retention policy and remain exact-store scoped.
7. Cost ledger totals remain unchanged after customer anonymization.
8. Shop-redact removes one connection's data while another store in the tenant remains intact.
9. Uninstall disables only one connection and prevents further permit issuance/delivery.
10. Failed/partial processing remains retryable; COMPLETED is written only after the full required operation is confirmed.
11. Export contains only the requested customer and exact store, is delivered through the approved secure channel, and is not exposed in ingress logs or caller responses.

## 7. Explicit non-actions

No processor, export artifact, deletion function, retention migration, uninstall cutover, or production change is implemented here. The existing privacy ingress remains review-only. Legal retention decisions and Shopify policy review are required before any destructive processor is enabled.
