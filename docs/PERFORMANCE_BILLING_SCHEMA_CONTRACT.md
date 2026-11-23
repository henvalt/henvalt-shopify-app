# Performance billing V1 — schema and transaction contract

**Status:** Engineering proposal only. Not a deployable migration.
**Date:** 2026-11-23
**Scope:** Versioned merchant agreement, immutable fee assessment, and safe separation from legacy Shopify subscription billing.

## 1. Live schema facts this design must preserve

Read-only inspection of the connected Supabase project established:

- `henvalt.revenue_ledger` is the durable recovery accounting source. Its entries distinguish `RECOVERY` (positive amount) from `ADJUSTMENT` (negative amount), carry tenant, currency, `billable`, attribution confidence, billing status, and optional attribution/order references.
- `henvalt.order_attributions` is unique on (tenant_id, order_id), and has a confidence enum including `CONFIRMED`.
- `henvalt.billing_measurements` is legacy subscription billing: it requires a billing period and a non-null percentage, and its legacy measurement function uses the subscription account's rate.
- `henvalt.billing_accounts` is Shopify-only and carries recurring amount, subscription ID, usage-line-item ID, plan and Shopify entitlement status.
- Existing billing/revenue tables have RLS enabled and no direct authenticated table grants; service-role access is the current server path.
- The existing recovery-to-billing function posts the ledger first, then returns `SHOPIFY_SUBSCRIPTION_NOT_ACTIVE` when there is no active Shopify subscription. It must not be loosened to create the new commercial model.

## 2. Explicit separation

Do not repurpose or widen these legacy objects for performance billing:

- `billing_accounts`
- `billing_measurements`
- `billing_usage_charges`
- `control_plane_claim_billing_usage`
- `control_plane_record_billing_usage_result`

Do not use Shopify subscription `ACTIVE` as the acceptance signal for a performance agreement. Do not make a zero-rate Shopify account to simulate a free performance plan. Do not change the existing delivery entitlement trigger as a shortcut.

New performance tables belong in the private `henvalt` schema, RLS enabled, with no browser-role grants. The browser must never be able to insert/update fee assessments or agreement acceptance directly.

## 3. Proposed data model

### `performance_agreements` — versioned commercial acceptance

One row represents one immutable version of terms for a tenant.

Required fields:
- `id uuid primary key`
- `tenant_id uuid not null references henvalt.tenants(id)`
- `version integer not null`
- `status text not null` — DRAFT, ACTIVE, PAUSED, SUPERSEDED, TERMINATED
- `fee_model text not null` — PERFORMANCE_SHARE
- `fee_basis text not null` — CONFIRMED_BILLABLE_RECOVERY
- `fee_rate_percent numeric(7,4) null` — NULL until accepted; bounded 0–100
- `currency_policy text not null` — SAME_CURRENCY_ONLY for V1
- `currency char(3) null` — required before activation if the agreement fixes one currency
- `terms_version text not null`
- `terms_sha256 text not null`
- `accepted_at timestamptz null`
- `accepted_by uuid null`
- `acceptance_method text null`
- `effective_at timestamptz null`
- `supersedes_agreement_id uuid null`
- created/updated timestamps

Activation constraint: ACTIVE requires non-null accepted rate, accepted_at, accepted_by, terms hash, effective_at, and supported fee basis. DRAFT may have a NULL rate. Exactly one ACTIVE agreement per tenant. Do not infer acceptance from app installation, OAuth, billing-account status, or a checkbox that is not tied to the exact terms hash.

A new rate or terms change creates a new version; it never edits the accepted terms/rate on an existing version. Pause/termination is an explicit lifecycle action with actor, timestamp and reason recorded in audit history.

### `performance_fee_measurements` — immutable earned-fee snapshots

One row per billable recovery ledger entry:
- `id uuid primary key`
- `tenant_id uuid not null`
- `agreement_id uuid not null`
- `ledger_entry_id uuid not null`
- `recovered_revenue numeric(18,2) not null check > 0`
- `fee_rate_percent numeric(7,4) not null check between 0 and 100`
- `fee_amount numeric(18,2) not null check >= 0`
- `currency char(3) not null`
- `ledger_created_at timestamptz not null`
- `agreement_version integer not null`
- `terms_sha256 text not null`
- `idempotency_key text not null`
- `created_at timestamptz not null`

Required uniqueness:
- unique (tenant_id, ledger_entry_id)
- unique (tenant_id, idempotency_key)

The agreement version, rate, hash, currency, amount and fee are snapshots. Later agreement edits cannot recalculate historical fees. Rows are append-only. Corrections are separate adjustment records; never update or delete an earned-fee snapshot to hide a refund.

### `performance_fee_adjustments` — refund and correction trail

Separate append-only rows referencing the original fee measurement and, where available, the negative `revenue_ledger` adjustment entry. Record adjustment kind, amount, currency, reason, source event ID, idempotency key, actor/system origin and created_at. Enforce same tenant and same currency. Never silently mutate a settled collection. A future collection adapter can decide whether a credit offsets an open receivable or becomes a future credit balance.

### Collection is intentionally not modelled yet

Do not add provider IDs or claim money was collected until a provider is selected and verified for the intended merchant countries. The fee measurement means “earned/measured”, not “invoiced”, “charged”, or “collected”. When the collection provider is chosen, add a separate receivable and provider-attempt state machine with durable idempotency and ambiguous-timeout reconciliation.

## 4. Exact V1 measurement transaction

A server-only RPC should execute this sequence in one database transaction:

1. Lock the target `revenue_ledger` row `FOR UPDATE`.
2. Confirm tenant ownership from the ledger row; never trust a tenant ID supplied by the browser or caller.
3. Require `entry_type = 'RECOVERY'`, `billable = true`, `attribution_confidence = 'CONFIRMED'`, positive amount, and valid three-letter currency. Adjustments are not fee bases.
4. Verify the linked order attribution, if present, is for the same tenant and order and is also CONFIRMED. If the ledger's confidence is not confirmed, do not assess a fee.
5. Select the single ACTIVE agreement whose effective interval covers the ledger entry's recovery/order timestamp. If no accepted agreement exists, return a non-error `AGREEMENT_NOT_ACTIVE` result and create no measurement.
6. Enforce the agreement currency policy. V1 rejects currency mismatch; no implicit FX, guessed exchange rate, or silent currency conversion.
7. Calculate `round(recovered_revenue * fee_rate_percent / 100, 2)` using numeric arithmetic.
8. Insert one immutable fee snapshot with a deterministic idempotency key derived from the tenant and ledger entry. Use `ON CONFLICT (tenant_id, ledger_entry_id) DO NOTHING`, then return the already-existing row on retry.
9. Never change `revenue_ledger.billing_status` to represent collection of a performance fee. That column remains part of the legacy billing pipeline until a separate migration defines cross-model semantics.

A rate of NULL is invalid for an ACTIVE agreement. A rate of 0 is a valid explicitly accepted rate and produces a zero fee snapshot; it must never be treated as missing acceptance.

## 5. Function and privilege boundary

- Put all RPCs in the non-exposed `henvalt` schema.
- Use SECURITY DEFINER only where required for the service-side transaction, with fixed `search_path = henvalt, pg_temp`.
- Revoke EXECUTE from PUBLIC, anon and authenticated; grant only to the server role used by the authenticated Edge Function.
- Do not expose a service-role key to the browser.
- Keep RLS enabled on every new table. Do not grant browser roles direct table writes.
- Run Supabase security and performance advisors after the final migration is applied in a staging project.
- Verify that the Edge Function authenticates the Shopify tenant/shop mapping server-side before calling the RPC.

## 6. Dashboard contract — never conflate states

Expose distinct totals:
- **Recovered revenue:** confirmed, attributed recovery amount from the revenue ledger.
- **Earned HENVALT fees:** sum of immutable performance fee measurements.
- **Credits/adjustments:** separately netted and auditable.
- **Outstanding:** earned fee less valid credits and confirmed collections, only once a collection system exists.
- **Collected:** provider-confirmed successful collection only.
- **Email cost:** known provider cost; show “unpriced” count and never present missing costs as zero.

The existing `control_plane_billing_summary` currently reads legacy `billing_measurements` and returns a subscription-oriented status/usage label. Do not relabel its current output as performance billing. A new summary RPC must explicitly name the model and return null/zero-safe values for agreement state, fee rate, earned fees, adjustments, collected amount and outstanding amount. If no agreement exists, say “No performance agreement accepted”; do not imply fees are owed.

## 7. Delivery entitlement remains a separate gate

Fee acceptance is not sufficient permission to send. Delivery must independently require:
- active tenant and connected shop;
- explicit per-flow recovery enablement;
- verified sender identity and completed legal sender profile;
- recipient consent and jurisdictional eligibility;
- suppression/unsubscribe checks;
- finite merchant-approved email budget and known cost ownership;
- no uninstall, pause, cancellation or revoked authorization.

The current test tenant's recovery master switch and all four flow toggles remain OFF. Preserve this until end-to-end test evidence and merchant configuration are complete.

## 8. Required automated test matrix

### Agreement acceptance
1. DRAFT with NULL rate can be stored but cannot be activated.
2. ACTIVE without accepted_at, accepted_by, terms hash, or effective_at is rejected.
3. Accepted rate and terms hash cannot be edited in place.
4. A second active agreement for the same tenant is rejected.
5. Paused/terminated agreement creates no new fee measurements.

### Fee eligibility and math
6. Confirmed + billable + RECOVERY ledger entry with an active agreement produces one fee snapshot.
7. PROBABLE/POSSIBLE/UNATTRIBUTED entries produce no fee.
8. Non-billable, ADJUSTMENT, zero/negative entries produce no fee.
9. Missing agreement or NULL rate produces no fee and no receivable.
10. 0%, fractional percentage and 100% calculations round to two decimals deterministically.
11. Currency mismatch is rejected; no FX lookup occurs.
12. A ledger entry from before agreement effective_at produces no fee.

### Concurrency and corrections
13. Two concurrent calls for the same ledger entry create exactly one measurement.
14. Retry returns the original snapshot even if agreement terms subsequently change.
15. Duplicate refund event creates one adjustment.
16. Partial and full refund adjustments never rewrite the original measurement.
17. Adjustment currency mismatch is rejected.
18. A collection timeout is UNKNOWN and cannot mint a second receivable/provider idempotency key.

### Authorization and operations
19. anon/authenticated cannot read or write private billing rows or execute privileged RPCs.
20. service-role RPC rejects caller-supplied tenant mismatch and resolves tenant only from the ledger.
21. Uninstall/pause/cancellation blocks delivery claims independently of earned fee state.
22. Provider egress remains disabled in tests; no real charge or email is sent.

## 9. Rollout sequence

1. Implement tables, constraints, immutable triggers, service-only RPC and tests in isolated staging.
2. Compare legacy and performance calculations on synthetic fixtures; never write to production ledger.
3. Implement a separate Edge Function and dashboard contract.
4. Select collection provider and merchant acceptance UX; add receivables only after this decision.
5. Run security/performance advisors, tenant-isolation tests and concurrency tests.
6. Keep production recovery disabled until sender/legal profile, consent, budget, shop install, fresh event ingestion, attribution, and delivery acceptance are independently verified.
7. Enable one controlled merchant only after explicit commercial approval and end-to-end test evidence.

## 10. Explicit non-goals / open decisions

This proposal does not choose a percentage, fee window, refund liability rule, email-cost owner, payment provider, invoicing cadence, tax treatment, or legal agreement wording. Those require explicit business decisions. It does not change production schema or behavior.
