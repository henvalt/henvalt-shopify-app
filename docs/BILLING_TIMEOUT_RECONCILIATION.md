# HENVALT Shopify usage-charge timeout reconciliation

Status: verified API contract and implementation plan; not yet wired into the worker or exercised against a development store.

## Why this exists

A timeout after Shopify accepts `appUsageRecordCreate` is an ambiguous outcome. HENVALT must not mark the charge failed or generate a new idempotency key. The original persisted key remains the identity of the charge.

Shopify's Admin GraphQL `AppUsageRecord` exposes `idempotencyKey`, and `AppSubscriptionLineItem` exposes a paginated `usageRecords` connection. This provides an exact reconciliation key; amount and timestamp matching alone are not sufficient.

## Provider lookup

The stored charge contains the exact `subscriptionLineItemId`, but Shopify's `AppSubscriptionLineItem` is not a `Node` type. Do not query it directly through `node(id:)`. Resolve the parent subscription first through the app installation, then query that `AppSubscription` node.

First, find the subscription that owns the stored line-item ID:

```graphql
query HENVALTFindUsageSubscription($first: Int!, $after: String) {
  currentAppInstallation {
    allSubscriptions(first: $first, after: $after) {
      edges {
        node {
          id
          status
          lineItems {
            id
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

Paginate `allSubscriptions` until the exact stored `subscriptionLineItemId` is found. Then query the parent `AppSubscription` by its ID:

```graphql
query HENVALTUsageRecordReconciliation(
  $subscriptionId: ID!
  $first: Int!
  $after: String
) {
  node(id: $subscriptionId) {
    ... on AppSubscription {
      id
      lineItems {
        id
        usageRecords(
          first: $first
          after: $after
          reverse: true
          sortKey: CREATED_AT
        ) {
          edges {
            node {
              id
              idempotencyKey
              createdAt
              price {
                amount
                currencyCode
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
}
```

Filter the returned line item by exact ID, then match `idempotencyKey`, amount and currency. Paginate the usage-record connection until the target charge's creation window is covered or the connection is exhausted. If subscription lookup, pagination, throttling, or transport fails, the result is inconclusive.

## Reconciliation decision table

| Provider lookup result | Required HENVALT action |
|---|---|
| Exactly one record with matching idempotency key, line item, amount and currency | Persist its Shopify usage-record ID and mark the charge SUBMITTED; mark the measurement and ledger entry BILLED in the same controlled database operation |
| No match after a complete lookup | Keep the original idempotency key; allow a controlled retry or operator decision, never mint a new key |
| Lookup incomplete, rate-limited, or timed out | Keep PENDING; do not mark FAILED and do not issue a new mutation based on an inconclusive lookup |
| Matching key but amount, currency, or line item differs | Stop and require operator review; do not mutate the charge |
| More than one matching record | Stop and require operator review; preserve all provider IDs for investigation |

## Required state and authorization work

The candidate migration now persists a separate `reconciliation_status` on each billing charge and exposes a bounded queue RPC for unresolved cases. The worker calls `control_plane_mark_billing_reconciliation_required` when its fifth attempt has an ambiguous outcome. The scheduler discovery query excludes `REQUIRED` and `MISMATCH` charges. The migration supplies service-role-only, tenant-bound read and resolution RPCs. A new `henvalt-billing-reconciliation` Edge Function validates the Supabase Auth session, requires exactly one OWNER/ADMIN membership, derives the shop from the active tenant connection, and requires an active test-mode billing account before calling those RPCs. It never accepts a client-supplied tenant or shop as authority and records the authenticated user ID as the operator reference. The service-role key remains server-side. Before it accepts `MATCHED` or `NOT_FOUND_CONFIRMED`, the function retrieves the stored Shopify access token server-side and independently queries Shopify Admin GraphQL API version `2026-10` for the owning subscription, exact line item and usage records. It compares the stored idempotency key, amount and currency; browser-supplied evidence is ignored. A no-match resolution requires the usage-record connection to be fully paginated within the bounded lookup window; incomplete lookups fail closed. The current implementation scans subscription pages in batches of 50 (up to 25 pages) and usage-record pages in batches of 50 (up to 20 pages). It stops early when the exact idempotency key is found; a no-match decision is permitted only after the usage-record connection is exhausted. If either safety bound is reached before completion, the function returns an unavailable result and does not change the charge. These changes are candidate-only and have not been deployed.

1. Validate the candidate migration and Edge Function against isolated Supabase staging with the exact production schema, roles and PostgREST JWT claims.
2. Deploy the candidate dashboard panel and Edge Function to isolated staging; verify OWNER/ADMIN access, member denial, multi-tenant denial and server-derived shop scope.
3. Exercise all three resolutions (`MATCHED`, `NOT_FOUND_CONFIRMED`, `MISMATCH`) against Shopify development-store evidence.
4. Add alerting for unresolved `REQUIRED` / `MISMATCH` rows and operational ownership for the queue.
5. Complete the timeout-after-acceptance, pagination, concurrent reconciliation and no-duplicate-charge end-to-end scenarios.

No operator action may accept an arbitrary shop/tenant pairing, overwrite a SUBMITTED charge, or replace the persisted idempotency key.

## Acceptance tests still required

- Shopify accepted the usage record but the HTTP response was dropped; the next reconciliation finds the exact idempotency key and commits SUBMITTED without a second mutation.
- Shopify did not accept the usage record; a complete lookup finds no match and a retry reuses the original idempotency key.
- Provider lookup times out or is rate-limited; HENVALT remains PENDING and sends no mutation.
- A key match with the wrong amount/currency/line item is rejected for operator review.
- Pagination crosses the original charge timestamp and does not falsely report NOT_FOUND.
- Two concurrent reconcilers cannot double-record or overwrite the charge.
- The operator resolution is tenant-bound, audited and cannot rewrite a submitted charge.
- Incomplete no-match evidence is rejected without changing the charge.
- A wrong-shop lookup cannot read or resolve another tenant's charge.
- `MISMATCH` remains excluded from scheduler retries.
- An incomplete no-match lookup is rejected and leaves the charge in `REQUIRED`.
- A wrong-shop lookup cannot read or resolve another tenant's charge.
- `MISMATCH` remains excluded from scheduler retries until a new audited resolution is recorded.

## Release boundary

This document does not deploy or call Shopify. The worker remains candidate code; the production project has no billing worker deployment or refund-credit-offset migration. The scheduler candidate remains inactive and uses an invalid staging hostname.
