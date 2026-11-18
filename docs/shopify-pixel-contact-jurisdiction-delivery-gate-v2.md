# Cart/browse contact and jurisdiction delivery gate — 18 November 2026

Status: **design and validation gate only**. No cart/browse send is enabled. No production migration, Edge Function, Worker, Shopify app, billing configuration or n8n workflow is changed by this document.

## Findings from tracing the existing SQL path

The current V2 delivery chain is deliberately checkout-specific:

- `resolve_shopify_delivery_context_v2` joins an opportunity to `shopify_checkout_recovery_candidate_v2` and `shopify_checkout_identity_v2`.
- `issue_shopify_delivery_permit_v2` repeats those checkout-candidate and checkout-identity joins, and requires an OPEN checkout plus a supported checkout country.
- `consume_shopify_delivery_permit_v2` repeats the checkout joins and rechecks current consent, store/app/tenant state, order conversion, sender/provider and billing entitlement before it creates the send attempt.
- A pixel-backed opportunity has `candidate_id = NULL` and `checkout_identity_id = NULL` by the source-shape constraint. It therefore cannot satisfy those joins. Do not relax the joins or fabricate checkout identifiers.

The cost-reservation path is merchant-wide, not store-local:

- An authorized send attempt fires the cost-reservation trigger.
- The trigger locks the tenant's billing-account row with `FOR UPDATE`, checks provider unit cost in the merchant billing currency, aggregates RESERVED and SETTLED reservations across that tenant, checks the monthly email limit and inserts the reservation in the same transaction.
- FAILED releases the reservation, SUBMITTED settles it and AMBIGUOUS retains it.
- The generalized recovery path must call this same reservation mechanism exactly once; it must not add a parallel cart/browse cost counter.

## Missing evidence for cart and browse

A pixel candidate can contain a pseudonymous customer reference, but that is not a deliverable contact. It does not prove:

- Shopify currently exposes a usable email for that customer;
- the customer belongs to the same exact installation at lookup time;
- current email-marketing consent is timestamped and SUBSCRIBED;
- the customer has not unsubscribed, complained, bounced or been suppressed;
- a supported legal jurisdiction can be established.

The current jurisdiction projector stores a two-letter country from a verified checkout shipping/billing address on a checkout identity. A cart or browse session may never produce a checkout. Store locale, currency, browser locale, IP geolocation and inferred country are not acceptable substitutes.

## Required shared evidence model before implementation

1. **Exact-store contact lookup:** resolve the customer GID through the same connection's active offline token and Shopify Admin API. Fetch only the email and minimum country evidence needed. Treat missing, redacted, inaccessible or malformed fields as unavailable. Never accept email or customer ID from n8n/browser as authority.
2. **Country evidence:** prefer a country code returned from a trusted Shopify customer address lookup. Persist only normalized ISO alpha-2 country, evidence source, observed time, and a versioned policy decision. Do not persist street address, postcode or phone. If no reliable country exists, remain blocked. State-level rules must be explicit where required; a country-only value cannot silently satisfy a state-specific rule.
3. **Consent:** use the current exact-store `shopify_customer_email_consent_v2` row and append-only evidence. Recheck it immediately before provider submission. Analytics consent and pixel marketing signal never authorize email. Missing timestamp, UNKNOWN, PENDING, UNSUBSCRIBED, REDACTED or conflicting evidence blocks.
4. **Suppression and conversion:** recheck exact-store customer/fingerprint suppression, complaint, hard bounce, unsubscribe, merchant pause, same-store order and store/app/tenant lifecycle at authorization and permit consumption.
5. **Single-use authorization:** one service-only function must bind opportunity, intervention, customer identity, source candidate, connection, sender and provider. It must issue a short-lived permit and create one idempotent send attempt. Pixel source shape remains explicit; checkout identifiers stay NULL.
6. **Cost reservation:** inserting the authorized attempt must trigger the existing tenant-wide locked reservation. Missing cost, currency mismatch, cap exhaustion or monthly limit failure rolls back the attempt and permit consumption. Do not pre-check a cap without an atomic reservation.
7. **Provider boundary:** recipient email stays transient inside the trusted delivery Edge Function. n8n receives opaque IDs and status only. A provider timeout is AMBIGUOUS and must not be automatically resent. Keep the existing three workflows; do not add a fourth or a parallel direct-send path.

## Required acceptance matrix

| Scenario | Expected result |
|---|---|
| Same customer/product/browser references in two stores | Separate contact and country lookups; no cross-store joins |
| No customer identity or no email | No permit, attempt, reservation or provider call |
| Email redacted by Shopify | No permit or provider call |
| Consent false, stale, missing timestamp or withdrawn | Block at final authorization and permit consumption |
| Country missing or unsupported | Block; no locale/IP/currency fallback |
| Store A unsubscribe or complaint | Store A blocked; Store B remains independently evaluated |
| Same-store order arrives after candidate creation | Candidate suppressed; any unused permit rejected |
| App/store uninstall or tenant suspension | No new or consumed permit |
| Duplicate/concurrent permit requests | At most one send attempt and one reservation |
| Monetary cap, currency or monthly limit failure | Transaction rollback; no provider request |
| Provider timeout | AMBIGUOUS; reservation retained; no blind retry |

## Release boundary

Cart/browse remain metadata-only and review-gated. Checkout delivery remains the only candidate delivery shape, and even that requires owner-controlled app setup, protected customer-data approval, verified sender/provider/billing configuration, and a staged runtime cutover. This document does not authorize any of those actions.
