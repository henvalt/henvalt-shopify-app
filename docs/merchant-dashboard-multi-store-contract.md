# Merchant dashboard multi-store contract

Status: implementation contract; no dashboard source or production API changed.

## Verified current behavior

The deployed merchant dashboard Edge Function authenticates the Supabase user, requires exactly one tenant membership, then queries active Shopify connections for that tenant. It returns 409 active_shop_connection_required unless exactly one active connection exists.

The same function calls shop-domain-keyed dashboard/revenue RPCs, then queries revenue_ledger directly using tenant_id, entry_type=RECOVERY, confirmed attribution and date range. It does not filter by immutable Shopify connection. The current API therefore does not provide a safe store selector and can return tenant-wide ledger rows for a shop-scoped request.

## Required API behavior

1. Authenticate the user against Supabase Auth; do not trust decoded JWT claims alone.
2. Resolve every tenant membership for the authenticated user.
3. Return only active Shopify connections whose tenant membership is authorized.
4. Accept a selected connection ID, not an arbitrary shop domain, from the browser.
5. Validate that selected connection belongs to an authorized tenant and is active.
6. Resolve shop domain and app identity server-side from that connection.
7. Return a store selector list and clear selection-required state when multiple stores exist.
8. Keep merchant-account-wide analytics separate and explicitly labeled; do not combine them with store-specific numbers without showing scope.
9. Filter store-specific activity, recoveries, revenue ledger, billing and settings by immutable connection lineage. If legacy rows lack trustworthy connection lineage, quarantine or label them unresolved; do not backfill from unverified metadata.
10. Apply date ranges consistently in selected store timezone and currency context.

## UI behavior

- Store selector is visible in workspace header when more than one authorized store exists.
- Selected store is part of dashboard query key and refreshed when changed.
- Switching stores clears cached store-specific detail data before rendering the next store.
- Empty states distinguish no activity from failed or unverified connection.
- Tenant-wide totals are labeled merchant-wide and never displayed as selected-store totals.
- No synthetic activity, demo recovered revenue or fabricated attribution is allowed.

## Acceptance tests

- User with one store sees existing single-store experience.
- User with two stores sees only those two authorized stores.
- User cannot request another tenant's connection ID.
- Switching A to B changes every store-specific data source and clears A's detail cache.
- Reused customer/order/checkout identifiers do not mix A and B.
- Store A dashboard ledger excludes Store B revenue.
- Merchant-wide totals reconcile to sum of authorized store totals without duplicate entries.
- Legacy rows with unknown store lineage are not silently assigned to either store.
