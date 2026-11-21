# V2 contact, consent and delivery authorization contract

Status: design contract for branch-only implementation. No production activation.

## Purpose

Connect exact-store checkout recovery candidates to a safe, auditable email send without feeding them into tenant-scoped legacy tables or exposing customer data to the browser.

## Required identity chain

Every send must be traceable through this immutable chain:

app_key → shopify_connection_id → tenant_id → verified webhook receipt → checkout identity → recovery candidate → customer identity → consent evidence → opportunity → intervention → delivery request → provider receipt

Every link must resolve to the same shopify_connection_id and tenant_id. A missing or mismatched link fails closed.

## Contact resolution policy

- Prefer server-side Shopify Admin API lookup using the exact installation's offline token and V2 customer Shopify ID.
- Do not resolve by email alone, tenant-wide customer ID or another store's customer record.
- Do not expose access tokens or Shopify API credentials to the browser or model prompts.
- Retrieve minimum contact fields only when preparing an authorized send; avoid storing raw webhook bodies or unnecessary address/phone fields.
- Missing customer ID, unavailable email, inaccessible customer, inactive connection, wrong app identity, token refresh failure or ambiguous record is not sendable.
- Guest checkouts without a verified exact-store customer/contact path remain ineligible until a separately reviewed method exists.

## Consent and suppression

- Require explicit current email-marketing consent from the exact store.
- Historical pixel marketing-consent signal is not sufficient to infer current Shopify customer email consent.
- Require a supported country/jurisdiction decision; unknown country or unreviewed jurisdiction is ineligible.
- Keep unsubscribe, complaint, bounce and merchant suppression checks. Do not treat one store's customer ID as globally unique.
- Re-check consent, suppression, order status, active store, active app, tenant state and merchant recovery switches immediately before provider submission.
- Opt-out or privacy request must stop future sends for the affected store/customer without suppressing unrelated stores.

## Delivery authorization

A new service-only authorization function must validate in one transaction or equivalent row-lock/idempotency guarantees:

1. delivery request, intervention, opportunity and candidate exist and link to the same tenant and exact connection;
2. connection and registered app are active and tenant is active;
3. candidate is still eligible and not converted, closed or superseded;
4. Shopify customer contact is resolved from the same connection;
5. explicit current email consent and jurisdictional eligibility are true;
6. no active store-scoped unsubscribe, complaint, bounce, suppression or merchant pause exists;
7. no order has converted the checkout since candidate discovery;
8. sender identity and provider configuration are verified;
9. billing/usage entitlement and merchant cost caps permit the send;
10. idempotency key has not already been claimed or sent.

Authorization is single-use and short-lived. A failed check returns a safe reason code and no recipient address.

## n8n boundary

- Keep the three existing workflows; no fourth workflow.
- Recovery worker may claim only V2 work whose authorization contract is complete.
- Delivery worker calls authorization immediately before provider submission and records provider result idempotently.
- Do not place raw Shopify payloads, OAuth tokens, Vault secrets or customer email in AI prompts or general diagnostic logs.
- Initial public release should not auto-send AI-generated replies. Replies should be human-reviewed drafts.

## Attribution and billing

- Only exact-store orders suppress exact-store candidates.
- Only confirmed attribution creates billable recovered revenue.
- Fee is calculated once from the confirmed ledger entry, using the agreed performance rate and currency.
- Refund/cancellation events adjust or reverse the same attribution/ledger chain idempotently.
- Store-specific and merchant-account-wide totals must be explicit; never present tenant totals as one store's totals.

## Required two-store regression cases

- Same Shopify customer ID in two stores produces separate identities.
- Same checkout token in two stores produces separate candidates.
- Store A order cannot stop Store B recovery.
- Store A consent revocation/unsubscribe cannot mutate Store B customer record.
- Store A delivery request cannot claim Store B intervention.
- Store A privacy deletion cannot remove Store B records.
- Reauthorization rotates only the route token for the same installation.
- Uninstall Store A does not disable Store B under the same tenant.

## Not authorized

This document does not authorize production migrations, Edge Function deployments, Cloudflare deployments, n8n edits, app releases, customer emails or applying candidate migrations.
