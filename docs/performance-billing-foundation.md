# ADR: Performance-based billing foundation

**Status:** Proposed; not deployed  
**Branch:** `work/performance-billing-foundation`  
**Date:** 2026-11-23

## Decision

HENVALT's commercial model is performance-based: no recurring subscription is required to begin a merchant-approved pilot; a fee is earned only on revenue that the attribution ledger marks as confirmed and billable. The fee rate must be explicitly accepted by the merchant and stored as a versioned contract term. A missing rate means **no fee is accrued and no charge is attempted**.

This ADR separates four things that must never be conflated:

1. **Recovered revenue** — a confirmed, attributable Shopify order value recorded in `revenue_ledger`.
2. **Earned fee** — recovered revenue multiplied by the accepted rate, net of subsequent refund/cancellation adjustments.
3. **Invoice/collection** — a provider-specific request to collect an earned fee.
4. **Delivery entitlement** — permission to run recovery and send messages, governed independently from whether an invoice has been collected.

No change in this document enables production recovery, sends an email, activates billing, or changes a merchant's accepted commercial terms.

## Live audit baseline (2026-11-23)

Project `ocyplckdojdubyrsxcxa`, tenant `ur4jvw-nz.myshopify.com`:

- Billing account: provider `SHOPIFY`, plan `STARTER`, recurring amount PKR 0, percentage 0%, status `PENDING`, test mode true, no subscription ID or usage line-item ID, email limit 5.
- Billing measurements: 0. Revenue ledger: 0 confirmed recoveries at audit time.
- `post_recovery_to_ledger_and_measure_billing(uuid)` posts the ledger entry, but only measures the fee if the billing account is `ACTIVE`; otherwise it returns `SHOPIFY_SUBSCRIPTION_NOT_ACTIVE`.
- `enforce_billing_entitlement_before_delivery()` allows production delivery only for `ACTIVE`; `PENDING` is allowed only in explicit test mode. It also enforces the account's monthly email limit and usage cap.
- `billing_accounts` is structurally Shopify-only: provider CHECK = SHOPIFY, plan CHECK = STARTER/GROWTH, and recurring subscription fields are required by the sync RPC.
- `billing_usage_charges` is structurally Shopify-only and requires a Shopify usage line item.
- `billing_measurements` already has a Paddle transaction reference, but no live Paddle collection path was verified.
- Existing idempotency exists for ledger posting/measurement by ledger entry. Refund adjustments are separate negative ledger entries.
- Service-role-only execution protects billing summary, claim and result RPCs.

## Why simply removing the ACTIVE check is unsafe

Removing the subscription gate alone would create an undocumented free-use mode with a zero-percent rate, no merchant-accepted contract, no collection provider, and an unknown email-cost exposure. It could also let a tenant's messages continue after a billing or merchant cancellation event.

The performance model must instead be explicit, versioned, and independently gated.

## Target contract model

Add a versioned tenant billing agreement (or equivalent normalized fields) with:

- `billing_model`: `PERFORMANCE` or legacy `SUBSCRIPTION`.
- `contract_status`: `DRAFT`, `PENDING_ACCEPTANCE`, `ACTIVE`, `PAUSED`, `CANCELLED`.
- `fee_percentage`: nullable numeric in [0,100]. NULL means no accepted rate; never infer a rate.
- `currency_policy`: initially same-currency-only; no implicit FX conversion.
- `effective_at`, `accepted_at`, `accepted_by`, `contract_version`, `terms_hash`.
- `collection_provider` and provider customer/account reference only after an actual provider is selected and connected.
- `email_budget_units` and/or merchant-owned provider credential verification, independent from the fee rate.
- Immutable history: changes to rate, model, currency, collection provider, or budget create a new contract version. Never rewrite prior measurements using a new rate.

The acceptance flow must record who accepted, when, the exact terms version/hash, and the rate displayed. A rate change is prospective only.

## Ledger and measurement invariants

1. Only `revenue_ledger` entries with `entry_type='RECOVERY'`, `billable=true`, and `attribution_confidence='CONFIRMED'` can create earned fees.
2. An order is counted once. Attribution idempotency and the ledger unique key remain authoritative.
3. Measurement snapshots the exact contract version, percentage, recovered amount, currency, ledger ID, and period. Never recalculate an old measurement from the current contract.
4. Refund/cancellation adjustments reduce net billable recovered revenue. If an adjustment arrives after an invoice was collected, it becomes a credit/offset in a future invoice or a refund workflow; do not silently mutate a settled invoice.
5. Currency mismatch is rejected. FX requires an explicit dated rate source and separate audit fields; out of scope for V1.
6. A zero or NULL fee rate does not create a collectible charge. A NULL rate is a hard “not accepted” state.
7. Collection retries are idempotent and provider-neutral. A timeout is an ambiguous state, not permission to submit a duplicate payment.
8. Display recovered revenue, earned HENVALT fee, invoiced amount, collected amount, credits, and outstanding balance as distinct metrics.

## Delivery entitlement invariants

- A performance contract can be active without a recurring subscription.
- A performance contract is not automatically active merely because the Shopify app is installed.
- Before delivery, require: active tenant, active Shopify connection, active accepted performance agreement (or explicit test mode), verified merchant/provider sending identity, recipient consent, suppression checks, and a finite email budget.
- Prefer merchant-owned MailerSend credentials and merchant-paid provider usage so HENVALT does not silently subsidize unlimited sends.
- Preserve hard monthly send limits and fail closed when the provider credential/domain is unverified.
- Uninstall, revoked connection, paused/cancelled agreement, privacy erasure, unsubscribe, or provider credential failure must stop new sends immediately.
- Never use a recovered-revenue fee cap as the only email-cost control; zero recovered revenue must not imply unlimited send budget.

## Provider strategy

Do not assume Shopify Billing or Paddle. Shopify App Store billing may require recurring/usage constructs that conflict with the no-subscription promise. Paddle may support an independent merchant billing relationship, but it is not currently verified as connected or implemented. Select a provider only after checking eligibility, supported countries, merchant onboarding, dispute/refund support, webhooks, payout availability, and provider fees.

Until a collection provider is selected:
- Keep fee measurement as an auditable receivable only after a merchant-accepted rate exists.
- Do not claim that money has been collected.
- Do not create payment attempts or alter production entitlement.

## Implementation sequence

1. Add the contract/version schema and RLS/privileges. Keep the legacy subscription path intact.
2. Add service-role-only RPC to accept/activate a performance agreement, with explicit rate and terms hash.
3. Update the attribution-posting function to measure only against the active contract version, never against subscription status.
4. Add a provider-neutral receivable/collection table with idempotency, attempt state, provider reference, error class, and reconciliation timestamps.
5. Add refund/credit handling for adjustments after measurement and after collection.
6. Update delivery entitlement to support accepted performance contracts, while retaining test mode and strict per-tenant send budgets.
7. Update dashboard API/UI to show earned vs invoiced vs collected distinctly.
8. Add provider integration only after provider selection and credentials are configured.
9. Test all transitions and run a test-mode end-to-end order attribution before enabling production recovery.

## Required automated tests

- No accepted contract / NULL rate: zero measurements, zero collection attempts.
- Accepted 0% rate: revenue can be displayed, fee is zero, no charge created.
- Accepted positive rate: exactly one measurement for one confirmed recovery ledger entry.
- Duplicate attribution webhook: no duplicate ledger entry, measurement, invoice, or payment.
- Unconfirmed attribution / non-billable ledger: no fee.
- Refund before invoice: fee basis reduced by adjustment.
- Refund after collection: credit/offset generated, settled invoice immutable.
- Rate change: old measurement retains original rate; new recoveries use new version.
- Currency mismatch: reject; no implicit conversion.
- Cancelled/paused contract: no new delivery and no new fee accrual after effective cancellation time.
- Performance contract active without subscription: delivery allowed only with verified sender and finite email budget.
- Email budget exhausted / provider unverified / consent revoked / shop uninstalled: delivery denied.
- Payment provider timeout: mark ambiguous and reconcile before retry; no duplicate charge.
- Tenant isolation: every RPC and collection query scoped to tenant; clients cannot write billing tables directly.

## Deployment gate

This ADR is not a production migration. Do not deploy until:
- the user approves the actual percentage and exact fee basis;
- a collection provider is selected and its country eligibility verified;
- the email-cost allocation and monthly cap are approved;
- the acceptance UX and terms are finalized;
- tests above pass in an isolated environment.

