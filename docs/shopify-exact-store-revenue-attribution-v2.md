# HENVALT exact-store recovered-revenue attribution V2

**Status:** candidate implementation in migrations 021–024; disposable PostgreSQL integration passed in CI run #335 for migrations 001–023. Migration 024 adds provider-event reconciliation for ambiguous delivery costs and is under current-head validation. All work is branch-only; no production billing or data changed.

## 1. Implemented evidence chain

The candidate V2 chain now includes:
- verified Shopify order receipt and immutable connection identity;
- exact-store checkout-token matching and order lifecycle projection;
- exact-store recovery opportunity, intervention and send-attempt lineage;
- provider acceptance and delivery timestamps from MailerSend event correlation;
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
- a refund after an invoiced/paid fee marks CREDIT_REQUIRED for manual financial reconciliation.

The current projection covers successful refunds/create transactions. Chargebacks and disputes are not yet projected, and no FX conversion is attempted.

## 4. Non-charging performance-fee ledger

shopify_recovery_fee_measurements_v2 records a measurement snapshot only when:
- the attribution is CONFIRMED with positive net recovered revenue;
- the tenant billing account is ACTIVE, not test mode, and has an explicit positive percentage;
- billing currency matches the recovered order currency.

The percentage is read from the merchant billing record; the migration does not choose 3%, 5%, 10% or any other rate. The ledger stores the percentage snapshot, recovered amount, fee amount, currency and optional Paddle transaction reference. No Paddle transaction or Shopify charge is created by these functions. The live billing account remains PENDING/test-mode with a zero performance percentage, so it remains non-billable.

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

## 6. Explicit non-actions

No production attribution policy was enabled. No production Supabase migration/function or billing row was changed. No performance percentage was selected. No Paddle transaction, Shopify charge, customer email or provider send was initiated by this work.
