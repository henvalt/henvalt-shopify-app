# HENVALT exact-store recovered-revenue attribution V2

**Status:** design gate only. Current order projection records exact-store checkout matching, but it does not yet create a recovery attribution or a performance-fee ledger. No billing or production changes are authorized by this document.

## 1. Verified source chain

The candidate V2 chain already provides:
- verified Shopify order receipt and immutable connection identity;
- order identity with exact `shopify_connection_id`, checkout token, total value, currency, financial status and timestamps;
- checkout identity and opportunity with exact connection and customer lineage;
- interventions and send attempts with exact connection, customer and provider identity;
- MailerSend provider event correlation to a send attempt.

The order projection matches only the checkout token within the same connection. A tenant-wide or same-email match is not sufficient evidence of recovery.

## 2. Attribution eligibility

An order can become a recovered-order candidate only when all are true:
1. The order receipt is HMAC-verified and projected for an active, exact Shopify connection.
2. The order has a non-empty checkout token and `checkout_match_status='MATCHED'`.
3. The matched checkout belongs to the same connection and tenant as the recovery opportunity.
4. At least one exact-store send attempt for that opportunity was provider-accepted (`SUBMITTED` or a later confirmed delivery state) before the order's creation time.
5. The order falls inside an explicitly configured merchant attribution window.
6. The order is in a billable paid state under the chosen policy; pending, authorized-only, voided, cancelled and fully refunded orders are not recovered revenue.
7. Order currency and value are valid. No foreign-exchange conversion or inferred currency is allowed.

An order that predates the email, lacks a checkout token, cannot be matched to the exact store, or has no eligible accepted send attempt remains unattributed.

## 3. Policies that must be explicit

Do not hardcode these decisions:
- Attribution window (for example, a merchant-configured number of hours/days).
- Touch model when multiple accepted interventions precede the same order (last eligible touch, first eligible touch, or another explicit model).
- Revenue basis: gross order total versus net merchandise revenue, and treatment of discounts, tax, shipping, duties and tips.
- Treatment of partial payments, partial refunds, full refunds, chargebacks and cancellations.
- Whether provider delivery confirmation is required or provider acceptance is sufficient.
- Currency and precision rules for the merchant's performance fee.

If the policy is missing, the system may record a matched order but must not create a billable attribution.

## 4. Proposed ledger model

Use separate immutable evidence and mutable reconciliation state:

- `shopify_recovery_attributions_v2`: one row per exact-store order attribution; unique on `(shopify_connection_id, order_identity_id)`; stores tenant, connection, opportunity, checkout, selected intervention/send attempt, attribution policy version, method, order currency, eligible revenue, timestamps and evidence references.
- `shopify_recovery_revenue_adjustments_v2`: idempotent positive/negative adjustments for refunds, chargebacks and cancellations; each source Shopify event is unique per connection.
- `shopify_recovery_fee_measurements_v2`: immutable fee calculation snapshot only after a merchant-approved positive performance percentage and confirmed net recovered revenue; stores currency, percentage snapshot, fee amount and external billing transaction reference when one exists.

Keep the source order and send-attempt evidence exact-store scoped. Do not duplicate the same order into more than one store's attribution ledger. A tenant may have a merchant-wide reporting aggregate, but it must be derived from store-attributed rows and never relabelled as per-store revenue.

## 5. Performance-fee safeguards

- Do not choose 3%, 5%, 10%, or any other percentage by default. The merchant-approved percentage must be explicit.
- The current live billing account is PENDING/test-mode with a zero performance percentage; it must remain non-billable.
- No fee is created from a checkout value-at-risk, an email send, an open/click, a provider acceptance, or an order that is not in the agreed paid state.
- Refunds and chargebacks must reduce eligible recovered revenue and reverse or credit the corresponding fee idempotently.
- Do not create a Paddle/Shopify charge until the attribution and adjustment ledger is reconciled and the merchant billing entitlement is active.
- Merchant email-provider cost reservations remain a separate ledger from HENVALT's performance fee.

## 6. Required acceptance tests

1. Same checkout token in Store A and Store B never cross-attributes.
2. Order created before the accepted recovery send is not attributed.
3. Order outside the configured attribution window is not attributed.
4. Missing checkout token or unmatched checkout remains unattributed.
5. Pending/authorized-only order is not billable; paid order follows the configured revenue basis.
6. Partial/full refund, cancellation and chargeback create idempotent negative adjustments.
7. Duplicate order/refund webhook deliveries do not duplicate attribution or adjustments.
8. Multiple accepted touches follow the explicit merchant touch policy.
9. Unknown currency or missing policy fails closed.
10. Zero or missing performance percentage produces no fee.
11. A fee snapshot is unique per attribution and billing period; retries cannot double-charge.
12. Multi-store merchant aggregate equals the sum of exact-store rows, with no duplicate order across connections.

## 7. Explicit non-actions

No attribution, fee, billing or refund processor is implemented here. No performance percentage is selected. No production billing record, Paddle transaction, Shopify charge, or live database row is changed.
