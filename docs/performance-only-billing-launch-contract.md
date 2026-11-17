# HENVALT performance-only billing launch contract

Status: contract and live audit only. No billing account, price, percentage, usage cap or production setting was changed.

## Live configuration observed on 17 November 2026

The live Supabase project contains one billing account with:

- status: PENDING
- plan: STARTER
- recurring amount: 0.00
- performance percentage: 0.00
- usage cap: 1,000.00 PKR
- monthly email limit: 5
- currency: PKR
- test mode: true

No billing measurements or revenue-ledger rows exist. This is not an active production billing arrangement and does not prove a fee has been charged.

## Product rule

HENVALT's intended commercial model is performance-only: no recurring subscription amount, and a fee is due only after a recovery is confirmed by the authoritative attribution and revenue ledger.

The actual percentage remains a commercial decision and must be confirmed before production configuration. Do not infer it from old tier drafts or hard-code a rate into production.

## Required charge chain

1. Shopify order is received and verified for the exact app and store.
2. The order is matched to the exact store's checkout and recovery lineage.
3. Attribution is evaluated with auditable evidence.
4. Only CONFIRMED attribution creates a billable recovery ledger entry.
5. The percentage fee is calculated once from that confirmed amount and currency.
6. Refunds, cancellations and adjustments update the same ledger lineage idempotently.
7. Shopify usage charge is submitted only when the subscription/usage entitlement is valid and the charge is within the approved cap.
8. Provider charge result is reconciled to the same measurement and ledger entry.
9. Dashboard displays confirmed recovered revenue, fee rate, fee amount, currency, status and reconciliation state.

## Non-billable cases

- No order, unverified order or order from a different store.
- Probable or ambiguous attribution.
- Duplicate webhook, duplicate ledger event or already billed measurement.
- Refund/cancellation that fully reverses the attributed recovery.
- Inactive app/store/tenant or invalid billing entitlement.
- Currency mismatch or missing fee configuration.
- A recovery event that did not create a confirmed revenue-ledger entry.

## Scope decision

The current billing RPCs resolve a shop to a tenant and aggregate or claim billing measurements by tenant. This implies merchant-account-level billing, not independent per-store subscriptions. That scope must be explicitly reflected in product copy and dashboard totals, or migrated to connection-level billing before claiming store-specific billing.

## Acceptance tests

- 0% fee creates no charge.
- Confirmed recovery at approved percentage creates exactly one fee measurement.
- Probable attribution creates no fee.
- Duplicate order/recovery event creates no duplicate fee.
- Refund/cancellation adjustment reverses or reduces the correct fee exactly once.
- Two stores in one tenant are aggregated only under an explicitly merchant-wide billing account.
- Store A's order cannot create or settle a Store B-specific charge.
- Usage-cap exhaustion prevents further charges and is visible to the merchant.
- Test mode cannot be mistaken for a production charge.

## Not authorized

No production billing settings, subscription, price, percentage, usage cap, payment method or Shopify charge were changed.
