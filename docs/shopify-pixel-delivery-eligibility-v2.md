# Cart/browse eligibility gate V2

Date: 18 November 2026  
Status: branch-only implementation; no delivery authorization enabled.

## Added in migration 032

`shopify_pixel_delivery_jurisdiction_policy_v2` is an explicit, versioned policy registry. It has no seeded countries or regions. A policy can be approved only with a non-empty legal review reference, approval timestamp, version, evidence-age limits and explicit region requirement. The only accepted location evidence source is the exact-store Shopify customer default address. That address is evidence, not legal approval.

`assess_shopify_pixel_delivery_eligibility_v2(opportunity_id)` is service-role-only and read-only. It checks:
- exact-store cart/browse opportunity and promoted candidate lineage;
- same exact-store customer identity;
- active tenant, app, store, Shopify token and read_customers scope;
- elapsed recovery delay;
- current contact availability and fresh country/region evidence;
- an exact country/region policy row that is approved and unexpired;
- fresh SUBSCRIBED email-marketing consent evidence;
- exact-store customer suppression and active privacy-redaction guards;
- same-store customer conversion after the candidate activity;
- active provider, verified sender and configured billing/cost prerequisites;
- absence of an already-created intervention.

It returns only a compact eligibility result and policy version. It never returns an email, token, address, raw contact evidence, or secret.

## Deliberate boundary

An `eligible=true` result means only that the opportunity may proceed to a separately reviewed authorization stage. The function does not create an intervention, permit, send attempt, n8n job, provider request, attribution record or billable reservation. It explicitly returns all of those flags as false.

The existing checkout-only resolver and permit functions are unchanged. Pixel delivery still requires a future delivery-time Shopify Admin re-resolution of email and marketing consent, recipient-fingerprint suppression check, a separate pixel-bound single-use permit/consume pair, and the existing atomic merchant-wide cost-reservation trigger. No legal country/region policy rows are inserted by this migration; those require documented review and explicit administrative configuration.


## Fresh Admin API marketing-consent evidence (migration 033)

The trusted contact resolver now requests `emailMarketingConsent { marketingState consentUpdatedAt }` in the same exact-customer Shopify Admin API query used for contact/location evidence. It writes the normalized consent state and timestamps to a separate append-only, exact-store evidence ledger. The recipient email remains transient and is not stored, logged, or returned.

The eligibility assessment now requires a positive Admin API `SUBSCRIBED` observation no older than five minutes with a non-null Shopify consent timestamp. Any consent webhook received after that Admin API observation invalidates it until a new trusted Admin API lookup occurs, regardless of webhook state. This is intentionally conservative and closes the stale-positive race; it is still not delivery authorization.

The new ledger and RPC are service-role-only, replay-checked, bounded to recent observations, and store no raw GraphQL response, email, address, or access token. No jurisdiction policy is seeded. Existing checkout authorization is unchanged.
