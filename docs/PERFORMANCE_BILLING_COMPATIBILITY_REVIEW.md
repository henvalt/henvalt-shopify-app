# Performance billing compatibility review

**Status:** Review only; no production changes
**Reviewed:** 2026-11-23
**Related work:** Draft PR #7 (V1 readiness / Shopify usage billing) and Draft PR #8 (performance billing ADR)

## Executive decision

Keep PR #7 intact as a legacy Shopify-subscription billing safety candidate. Do not merge its Shopify usage-billing worker into the performance-billing path as-is. Reuse selected accounting and concurrency protections only after their assumptions are separated from Shopify subscription entitlement.

PR #7 is substantially broader than a billing change: it includes provider-send interlocks, Shopify Pixel consent gates, dashboard attribution corrections, webhook replay/lease fencing, privacy processing, and workflow cutover candidates. Its billing worker is explicitly test-mode-only and expects a Shopify subscription usage line item. PR #8 defines a different commercial model: a merchant-approved percentage of confirmed recovered revenue, with no recurring subscription prerequisite.

Neither PR is production-approved. This review changes no deployed schema, Edge Function, n8n workflow, Shopify app version, or merchant setting.

## Evidence from PR #7

The billing-specific candidate set includes:

- Refund/cancellation credit allocation (202611220011_billing_refund_credit_offsets.sql).
- Billing result lock-order and monotonicity (202611220014_billing_result_lock_order_and_monotonicity.sql).
- Subscription-row locking during usage-charge claim (202611220015_billing_claim_subscription_lock.sql).
- Deterministic-failure reconciliation (202611220016_billing_deterministic_failure_reconciliation.sql).
- A Shopify usage-billing Edge Function and a billing-reconciliation Edge Function.
- An inactive candidate branch on the existing HENVALT_RECOVERY scheduler; no fourth n8n workflow is proposed.

The worker's claim RPC requires an ACTIVE billing account, a non-null Shopify usage_line_item_id, exactly one active Shopify connection for the tenant, and test_mode = true. The worker then submits appUsageRecordCreate with a persisted Shopify idempotency key. The candidate docs explicitly say the worker and scheduler are not deployed or exercised against a Shopify development store.

The candidate's refund-credit allocator is useful as an accounting reference: it serializes credit allocation, scopes credits by tenant and currency, preserves a charge's original amount on retry, and does not submit negative usage records. Its retry/reconciliation work also correctly treats ambiguous provider timeouts as unknown rather than as permission to mint a new charge identity.

## Live database compatibility findings

Read-only inspection of the connected project confirms:

- henvalt.billing_accounts.provider has a CHECK constraint allowing only SHOPIFY.
- plan_key allows only STARTER and GROWTH.
- The account model has recurring amount, subscription ID, and usage line-item fields.
- billing_measurements.henvalt_percentage is NOT NULL, so it cannot represent an unaccepted/missing performance rate.
- billing_usage_charges.provider also allows only SHOPIFY.
- billing_usage_charges requires a positive amount and a unique persisted idempotency key per tenant.
- The existing fee-measurement path is coupled to an ACTIVE subscription account. Simply removing that check would not create a safe performance model.
- Existing billing tables have RLS enabled and are not directly granted to authenticated; service-role access is the current data path.

This is why PR #8 must not be implemented by changing the old subscription status to ACTIVE, setting the percentage to zero, or loosening the current trigger. Those shortcuts would blur agreement acceptance, fee accrual, collection, and permission to send.

## Reuse map

| PR #7 capability | Performance model disposition |
|---|---|
| Confirmed-attribution revenue ledger | Reuse as the sole source of billable recovered revenue, after preserving the exact confirmed/billable predicate |
| Refund/cancellation adjustments and credit allocation | Reuse the accounting invariants, but define whether adjustments reduce an uncollected receivable or create a future credit after collection |
| Idempotency and monotonic provider-result handling | Reuse the pattern; implement against a provider-neutral receivable identity |
| Shopify usage-charge tables and appUsageRecordCreate worker | Keep isolated to legacy Shopify subscription billing; do not make it the performance collection abstraction |
| Subscription ACTIVE checks | Do not reuse as performance-contract entitlement |
| Test-mode-only scheduler branch | Keep inactive until a staging environment and an explicitly approved test agreement exist |
| Dashboard confirmed/net revenue work | Reuse the source-of-truth distinction; add earned, invoiced, collected, credited, and outstanding fee metrics separately |
| Global provider-send interlock | Preserve as a separate operational safety control; it is not a substitute for per-tenant consent or delivery entitlement |

## Required performance-billing separation

The next implementation should add a separate, versioned agreement model and separate fee/receivable records rather than broadening the existing Shopify-only constraints in place.

Minimum invariants:

1. A missing or NULL accepted fee rate means no fee measurement and no receivable.
2. A fee can be earned only from a confirmed, billable recovery ledger entry; count each ledger entry once.
3. Each fee measurement snapshots the exact agreement version, accepted percentage, ledger entry, amount, and currency. Later contract changes never rewrite history.
4. Refunds and cancellations create auditable adjustments; settled collections are not silently rewritten.
5. Currency mismatch is rejected in V1; no implicit FX conversion.
6. Collection provider and provider customer references remain absent until a provider is selected and verified.
7. Delivery entitlement is separate from fee collection: active agreement, active tenant/shop, verified sender identity, recipient consent/suppression checks, and a finite email budget are independent gates.
8. Uninstall, tenant pause/cancellation, agreement pause/cancellation, or budget exhaustion must stop new delivery claims.
9. All tenant-facing reads are derived from server-authorized tenant scope; browser-supplied tenant/shop IDs are never authoritative.
10. Existing subscription billing behavior remains unchanged for any legacy account until an explicit migration and compatibility test are approved.

## Remaining decision gates

No rate, fee basis, collection provider, email-cost ownership model, or merchant acceptance wording is inferred by this review. Those are commercial decisions that must be explicit before the corresponding collection path can be implemented or activated.

Before implementation is promoted beyond a draft branch:

- Confirm the fee percentage and exact billable revenue basis.
- Confirm how long after a recovery the attribution window remains open, and how refunds/partial refunds are treated.
- Choose a supported collection route for UK, US, CA, and AU merchants and verify its current eligibility and fees.
- Decide whether the merchant supplies the sending provider or HENVALT owns a capped sending budget.
- Approve the merchant-facing agreement and acceptance evidence.
- Validate migrations and authorization in isolated Supabase staging with production-equivalent roles, Vault, and Edge Functions.
- Exercise provider timeouts, duplicate events, concurrent refunds, uninstall, cancellation, and no-send paths end-to-end with provider egress blocked by default.

## Current release boundary

PR #7 remains draft and is not a production release. PR #8 remains draft and documentation-only. The connected production database was inspected read-only for this review. No migration was applied, no billing account was changed, no workflow was edited, and no customer email or provider charge was submitted.
