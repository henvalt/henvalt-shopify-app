# HENVALT exact-store recovered-revenue attribution V2

**Status:** candidate implementation across migrations 021–041. CI run #913 passed the full disposable PostgreSQL migration and integration suite through migration 041, including pixel attribution, refunds, dashboard metrics and two-store isolation. All work is branch-only; no production billing or data changed.

## 1. Implemented evidence chain

The candidate V2 chain now includes:
- verified Shopify order receipt and immutable connection identity;
- exact-store checkout-token matching and order lifecycle projection;
- exact-store recovery opportunity, intervention and send-attempt lineage;
- provider acceptance and delivery timestamps from MailerSend event correlation; delivery confirmation requires the signed provider event's actual timestamp, and out-of-order duplicates retain the earliest valid delivery time;
- successful refund transaction adjustments tied to the exact matched order.

Migrations 021–022 project exact-store order create/update/paid/cancelled topics and successful refunds/create transactions. Migration 023 creates the attribution and fee-measurement ledgers. The SQL integration test verified a paid order attributed to its eligible recovery send, followed by partial and full refund reconciliation.

## 2. Explicit per-store attribution policy

shopify_recovery_attribution_policies_v2 is disabled by default. A server-role-only policy setter requires:
- an explicit attribution window (1–720 hours);
- FIRST_ELIGIBLE_TOUCH or LAST_ELIGIBLE_TOUCH;
- SHOPIFY_TOTAL_PRICE as the recorded revenue basis;
- an explicit choice whether provider delivery confirmation is required.

Policy changes increment a version so each attribution records the policy version used. There is no default attribution window or default touch model. Policy activation is not performed automatically by the migration.

An order is eligible only when its verified projection matches a checkout in the same store, its customer identity matches that checkout/opportunity, it is in a paid or partially-refunded state with valid value and currency, and an eligible provider-accepted send occurred before the order inside the configured window. With delivery confirmation required, a DELIVERED state and timestamp are required; otherwise provider submission is the touch. Unmatched, pending, cancelled, voided, fully-refunded, unknown-currency, pre-send or out-of-window orders are not billable.

## 3. Refund reconciliation

The attribution row is unique per exact-store order. Refund adjustments are aggregated only for the same order, tenant, connection and currency. Partial refunds reduce net recovered revenue; full refunds reverse the attribution. The fee-measurement row is recalculated from the net amount:
- pending fees are reduced when a partial refund changes the amount;
- a full refund voids a pending fee;
- after invoicing or payment, the original recovered amount and fee amount remain immutable;
- adjusted recovered amount, adjusted fee amount and calculated credit delta are stored separately;
- collection state (INVOICED or PAID) is preserved while a separate reconciliation status signals CREDIT_REQUIRED or REVIEW_REQUIRED.

The current projection covers successful refunds/create transactions. Chargebacks and disputes are not yet projected, and no FX conversion is attempted.

## 4. Non-charging performance-fee ledger

shopify_recovery_fee_measurements_v2 records a measurement snapshot only when:
- the attribution is CONFIRMED with positive net recovered revenue;
- the tenant billing account is ACTIVE, not test mode, and has an explicit positive percentage;
- billing currency matches the recovered order currency.

The percentage is read from the merchant billing record; the migration does not choose 3%, 5%, 10% or any other rate. The ledger stores the percentage snapshot, original measured recovered amount and fee amount, adjusted post-refund amounts, explicit credit delta, currency and optional Paddle transaction reference. For an invoiced or paid measurement, refund reconciliation never overwrites the original billed fee; it records the credit required separately and preserves the INVOICED/PAID collection state. A separate reconciliation status communicates CREDIT_REQUIRED or REVIEW_REQUIRED. The missing-measurement trigger runs for both initial billing-account insertion and later activation/percentage changes. No Paddle transaction or Shopify charge is created by these functions. The live billing account remains PENDING/test-mode with a zero performance percentage, so it remains non-billable.

Merchant email-provider cost reservations are a separate ledger from HENVALT's performance fee.

## 5. Acceptance coverage and remaining work

Verified in CI run #335 (migrations 001–023):
1. a paid exact-store order matched to the correct recovery opportunity and send attempt;
2. a pending 5% fee measurement with no Paddle transaction;
3. a partial refund reducing net recovered revenue and fee;
4. a full refund reversing the attribution and voiding the pending fee.

Still required before launch:
- test first-touch and last-touch selection with multiple eligible sends;
- test delivery-confirmation-required policy and out-of-window/pre-send rejection;
- test same checkout token across stores and duplicate order/refund replay specifically against the attribution ledger;
- add chargeback/dispute projection and its fee-credit behavior;
- obtain the merchant's explicit approved performance percentage and fee basis;
- implement and reconcile actual billing collection only after legal/merchant approval.


## 6. Pixel cart/browse attribution (migration 040)

Cart and browse opportunities now use a separate attribution lineage; they do not fabricate or borrow a checkout identity.

A pixel opportunity can be attributed only when all of the following hold:
- the Shopify order is projected under the same immutable store connection;
- the order has an exact Shopify customer identity matching the pixel candidate and pixel send attempt;
- the order has no checkout-token match, so the pixel path cannot compete with checkout attribution;
- the order is paid or partially refunded, has a valid positive Shopify total price and currency, and is not cancelled;
- the pixel send attempt is SUBMITTED and has a signed MailerSend provider event already reconciled to that exact attempt;
- the provider touch is before the order and inside the explicitly configured attribution window;
- delivery-confirmation policy is honored: when required, only `activity.delivered` qualifies; otherwise a reconciled `activity.sent` or delivered event qualifies.

A sent/delivered event is evidence of a recovery touch, not recovered revenue. It never creates an attribution or fee by itself. The paid Shopify order is the revenue evidence. The attribution row stores `pixel_send_attempt_id`; `checkout_identity_id` and the legacy checkout `send_attempt_id` remain NULL. The same refund reconciler then reduces net pixel-attributed revenue and reverses a fully refunded order.

The candidate SQL integration test covers a sent-only non-attribution, delivered-event qualification, same-customer/same-store order attribution without checkout identity, one-opportunity/one-order protection, and dashboard isolation. The test fixtures are rolled back.

## 7. Exact-store V2 dashboard read model (migration 041)

The old dashboard summary reads legacy tenant-wide tables and is not a source of truth for the new V2 recovery engine. The candidate dashboard now calls `control_plane_dashboard_summary_v2` with an immutable `shopify_connection_id`. It reads V2 opportunities, send attempts, confirmed attributions and refund-adjusted net revenue only. It does not mix the legacy tenant-wide ledger into store-specific totals.

- Revenue and recovered-order counts come only from CONFIRMED V2 attribution rows.
- Pixel messages count only when a signed provider event has been reconciled to the attempt; checkout messages use provider-accepted attempt states.
- Refund reconciliation removes fully reversed amounts from confirmed dashboard totals.
- When more than one currency exists in a store's selected period, the API returns a mixed-currency signal rather than summing unlike currencies. The UI labels the total accordingly and formats activity amounts using their own currency.
- The merchant dashboard returns active stores for the authenticated tenant and requires an explicit store selection when more than one exists. The Shopify-session dashboard is already bound to the exact store from its validated session token.

These are candidate branch changes only. They do not replace or deploy the live summary RPC.

## 8. Validation update — CI run #913 (18 November 2026)

The full identity V2 workflow passed on commit `c3ae83951130a27444a06b9bc91db4dea405c25f`. The run applied candidate migrations 001–041 to disposable PostgreSQL, type-checked both Shopify pixel delivery and MailerSend webhook Edge Functions, ran the existing exact-store/privacy/delivery/cost suites, and exercised the new pixel recovery attribution and dashboard integration path.

The new regression assertions prove:
1. a reconciled `activity.sent` event alone does not satisfy a delivery-confirmation policy;
2. a reconciled `activity.delivered` event can qualify as a touch, but only a paid same-store order with the exact same customer identity creates recovered revenue;
3. pixel attribution stores no checkout identity or legacy checkout send-attempt reference;
4. one pixel opportunity cannot be reused to attribute a second order;
5. a partial refund reduces net recovered revenue, a full refund reverses the attribution, and dashboard recovered revenue returns to zero;
6. the V2 dashboard reports the attributed store's confirmed revenue while a second active store in the same tenant sees zero recovered orders and revenue;
7. the dashboard refuses to combine unlike currencies and supports explicit store selection for multi-store merchant workspaces.

This is branch validation only. The new migrations, Edge Function changes and dashboard UI have not been deployed.
## 9. Explicit non-actions

No production attribution policy was enabled. No production Supabase migration/function or billing row was changed. No performance percentage was selected. No Paddle transaction, Shopify charge, customer email or provider send was initiated by this work.


## 10. Checkout attribution touch selection hardening

The checkout attribution evaluator now ranks eligible send attempts across every recovery opportunity attached to the exact matched checkout, rather than selecting the newest opportunity first and potentially hiding an older eligible touch. Opportunities already consumed by another attributed order are excluded before ranking. FIRST_ELIGIBLE_TOUCH and LAST_ELIGIBLE_TOUCH therefore operate over the full eligible checkout touch set. A full multi-opportunity SQL fixture remains a launch acceptance requirement.


## 11. Database-enforced attribution and fee idempotency

The checkout attribution ledger has validated unique constraints for one attribution per exact-store order and one attribution per exact-store recovery opportunity. Fee measurements have a separate unique constraint per exact-store attribution. The evaluator also excludes consumed opportunities before touch ranking and uses conflict-safe insertion; a competing order that loses the opportunity race cannot create a second attribution. Fee creation is conflict-safe as well, so replayed attribution or billing-account activation cannot duplicate a fee measurement.

A new disposable-PostgreSQL metadata acceptance test verifies these unique constraints, exact tenant/store foreign-key lineage, enabled attribution/refund/billing triggers, and the explicit refund-credit columns. This test verifies schema enforcement, not a concurrent two-order attribution simulation; that behavioral race fixture remains outstanding. No production database was changed.
