# Cart/browse delivery boundary — engineering decision record

Date: 18 November 2026  
Status: **blocked by design; no send path enabled**  
Scope: branch-only review of PR #6. No production database, Edge Function, Worker, Shopify app, billing configuration, or n8n workflow was changed.

## End-to-end trace completed

The current checkout delivery path has three distinct controls:

1. `resolve_shopify_delivery_context_v2` binds the intervention to its checkout recovery candidate, checkout identity, exact store, customer identity, current consent, jurisdiction, provider, sender and billing account.
2. `henvalt-shopify-contact-delivery-v2` resolves the customer email transiently from Shopify Admin, fingerprints it in memory, obtains a short-lived permit, consumes the permit, and only then submits to MailerSend.
3. `issue_shopify_delivery_permit_v2` and `consume_shopify_delivery_permit_v2` independently join the checkout recovery candidate and checkout identity. Consumption repeats current state checks and creates the authorized attempt. The attempt insert invokes the merchant-wide cost reservation trigger.

The pixel opportunity model is intentionally different. For `ABANDONED_CART` and `BROWSE_ABANDONMENT`, the source-shape constraint requires `candidate_id`, `checkout_identity_id`, and `source_delivery_id` to remain NULL while `pixel_candidate_id` is populated. Promotion sets `REVIEW_REQUIRED`, creates no intervention, and grants no delivery authority.

Therefore the existing Edge Function cannot safely deliver pixel opportunities by swapping an ID or fabricating checkout linkage. Its public request shape accepts an intervention ID only; it does not accept a customer ID, pixel candidate ID, or recipient email from an untrusted caller.

## Contact evidence is not a delivery credential

The new contact-evidence resolver does an exact-store Shopify Admin lookup using the customer GID bound by the service-only SQL context resolver. It reduces the result to:

- contact available: boolean;
- country code: optional normalized ISO alpha-2;
- region code: optional bounded normalized value;
- lookup timestamp and opaque evidence ID.

It discards the email and raw address response. The resolver explicitly returns `send_authorized: false`. Shopify's default address is only an evidence source; it is not proof of the recipient's current location or a final legal determination.

## Critical implementation gaps before any cart/browse send

- A separately reviewed, versioned jurisdiction policy must define which combinations of country and region can be used, what evidence is acceptable, and when missing or stale evidence blocks. A country/region code must not silently become legal approval.
- Delivery-time email must be re-resolved from the exact Shopify customer GID inside the trusted delivery boundary. The preflight contact boolean is not enough.
- Current exact-store marketing consent and suppression must be checked at authorization and immediately before provider submission. Pixel analytics consent is not marketing consent.
- Conversion, customer redaction, app/store/tenant pause, sender/provider readiness and idempotency must be rechecked.
- The new authorization must bind the pixel opportunity and candidate without introducing fake checkout IDs, issue a short-lived single-use permit, and create one idempotent attempt.
- The authorized attempt must trigger the existing tenant-wide atomic provider-cost reservation. No second cart/browse counter or non-atomic pre-check is acceptable.
- Provider timeouts remain AMBIGUOUS; they must not be blindly retried. n8n must receive opaque identifiers and statuses, never recipient email.

## Engineering decision

Do **not** generalize the existing checkout resolver or permit functions. Do **not** create interventions from pixel candidates yet. Do **not** route cart/browse opportunities into the existing delivery Edge Function.

The next safe implementation batch is a separate, service-only pixel eligibility assessment and a separately scoped permit/consume path, with explicit SQL tests for cross-store isolation, consent withdrawal, suppression, order conversion, stale contact evidence, region-policy unknowns, duplicate/concurrent requests, and cost-cap races. Until that entire chain is implemented and validated, cart/browse remain review-only.

## Validation added

`tests/shopify-pixel-delivery-boundary-v2.test.mjs` locks the architecture boundary across:

- pixel-vs-checkout source shape;
- checkout-only joins at both permit issuance and consumption;
- intervention-only request shape of the delivery Edge Function;
- transient-only email handling and the no-send contact evidence resolver;
- bounded country/region evidence storage;
- reuse of the existing merchant-wide atomic reservation trigger.

The test is added to the Identity V2 CI workflow. This work is branch-only and does not authorize a production migration or deployment.
