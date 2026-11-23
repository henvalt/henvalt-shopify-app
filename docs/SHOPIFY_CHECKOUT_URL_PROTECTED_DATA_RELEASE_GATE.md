# Shopify checkout recovery URL: protected customer data gate

**Reviewed:** 2026-11-23  
**Shopify change announced:** 2026-11-19

## Deadline and required approval

Shopify announced that `abandoned_checkout_url` in `checkouts/create` and `checkouts/update` webhook payloads is removed for apps without access to all four protected customer fields:

- `read_customer_name`
- `read_customer_email`
- `read_customer_phone`
- `read_customer_address`

The effective date is **2026-12-01 for public apps** and **2027-01-01 for partner custom apps and merchant-created Dev Dashboard apps**. Partial approval is insufficient. Public apps need a Shopify data protection review; custom apps can enable the fields themselves in the Dev Dashboard. Development stores do not enforce this approval, so a development-store install is not proof that a production merchant will receive the field.

Official announcement: https://shopify.dev/changelog/posts/abandonedcheckouturl-now-requires-level-2-protected-customer-data-access

## HENVALT code-path assessment

The current Shopify webhook ingest normalizer maps `abandoned_checkout_url` to the normalized `destination_url` and stores it in checkout metadata. The recovery worker context resolves the destination from the checkout metadata. Its preflight requires a non-empty destination URL before the email can be sent.

If Shopify omits the field, HENVALT therefore fails closed: the checkout opportunity may still be recorded, but the recovery intervention cannot pass send preflight and is skipped. This avoids sending a broken checkout link; it also means the merchant does not receive checkout recovery for that event.

Do **not** fabricate a checkout URL, guess a token-based URL, or silently substitute a cart URL for an existing checkout. That could lose checkout state, discounts, shipping selections, or other buyer context.

## Required release action

1. Confirm the app's distribution type in Shopify Dev Dashboard. Do not infer it from the repository or OAuth screen.
2. For a public app, request access immediately: Dev Dashboard → Apps → HENVALT → Settings → Access requests → Protected customer data → Manage.
3. Request Customer data and all four fields above, provide a clear functional reason for each, complete Data protection details, save, and submit for review.
4. Verify the granted field access in the Dev Dashboard. Declaring `read_orders` and `read_customers` in OAuth scopes is not equivalent to approval for protected customer fields.
5. Test the webhook on a non-development/production-like store after approval, and assert that a valid checkout destination is present before enabling checkout recovery.
6. Keep recovery delivery disabled until this gate, consent checks, merchant sender identity, and billing entitlement are independently verified.

## Current code and test posture

- The current OAuth scopes include `read_orders` and `read_customers`; protected-field approval is a separate Dev Dashboard access request.
- The ingest and recovery worker paths already require a destination URL at send preflight. No fallback URL is generated.
- This document is a release gate, not proof that HENVALT has been approved.
