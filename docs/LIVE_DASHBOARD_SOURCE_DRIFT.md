# Live dashboard source reconciliation

**Status:** Verified drift; no runtime changes
**Reviewed:** 2026-11-23
**Scope:** `henvalt-merchant-dashboard` Edge Function and the dashboard bundle on the performance-billing branch.

## Finding

The currently deployed Supabase Edge Function `henvalt-merchant-dashboard` is ACTIVE at version 4. Its live source is not represented by the repository's `supabase/functions/henvalt-merchant-dashboard/index.ts` on `work/performance-billing-foundation`.

The live function:
- validates the bearer token against Supabase Auth;
- resolves exactly one tenant membership and exactly one active Shopify connection;
- validates a date range and granularity;
- calls `control_plane_dashboard_summary` and `control_plane_revenue_series`;
- reads confirmed recovery ledger rows, including joined order, attribution, and legacy billing measurement fields;
- returns revenue series, comparison, ledger and generated timestamp.

The repository branch's function source:
- uses a different helper-based REST implementation;
- validates membership and active connection, and calls `control_plane_dashboard_summary`;
- returns only summary + range + generated timestamp;
- does not include the live series/ledger read paths described above.

This is material source drift. Replacing the deployed function from the repository branch without first reconciling the newer live implementation would remove dashboard capabilities. The function is not safe to redeploy from the current branch source.

## Billing dashboard implications

The current dashboard HTML in the branch contains Overview, Recovery activity, Revenue ledger, Delivery and Settings. It has no Billing page or performance-agreement view. Its live API response includes legacy `billing_measurements` joined to recovery ledger rows, but those measurements are subscription-shaped and must not be presented as accepted performance fees.

The database currently has no performance-agreement or performance-fee tables, no confirmed recovery ledger rows, and no order-attribution rows for the audited test tenant. Therefore:
- no performance agreement can be displayed as accepted;
- no earned performance fee can be calculated or shown as payable;
- no amount can be represented as collected under a performance model;
- legacy Shopify billing data, if displayed, must be explicitly labeled as legacy subscription billing.

## Security properties to preserve during reconciliation

- Keep server-side Auth token validation; do not trust decoded JWT claims from the browser.
- Resolve tenant from the authenticated user's membership; never accept a tenant ID from query parameters.
- Require exactly one active tenant membership and one active shop connection unless the product intentionally introduces multi-store selection.
- Keep service-role credentials exclusively in Edge Function secrets.
- Preserve `cache-control: no-store` and tenant-scoped ledger filters.
- Do not expose provider secrets, billing credentials, or internal tenant IDs to the browser.
- Preserve the confirmed-attribution filter and do not count clicks, opens, visits, or probable attribution as recovered revenue.

## Reconciliation plan

1. Export and commit the exact currently deployed version 4 source as the canonical starting point, after comparing it against the existing repository file.
2. Add tests for Auth failure, zero/multiple memberships, zero/multiple active shops, invalid date range, tenant isolation, and service-role-only data access.
3. Extend the endpoint with a separately named performance-billing object only after the agreement/measurement schema exists. Until then return an explicit `NOT_CONFIGURED` state; never infer acceptance from legacy subscription fields.
4. Add a Billing page that separates recovered revenue, earned performance fee, credits/adjustments, invoiced, collected and outstanding. Null or absent agreement must mean no fee is owed.
5. Deploy only after source parity and preview verification; do not replace the live version with the older repository implementation.

## Release boundary

This document records a read-only finding. It does not change the deployed Edge Function, production database, billing settings, Shopify app, dashboard preview, n8n workflows, or sending state.
