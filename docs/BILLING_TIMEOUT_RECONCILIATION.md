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

The current worker returns `requiresOperatorReview` on an exhausted ambiguous attempt, but this is not yet a durable reconciliation state. Before production, implement:

1. A durable `RECONCILIATION_REQUIRED` marker (or equivalent fields) on the charge, set atomically when ambiguous attempts are exhausted.
2. A service-role-only read RPC that returns the exact tenant-bound charge envelope for reconciliation.
3. A service-role-only result RPC that accepts only a verified provider usage-record ID and records the reconciliation decision with an audit event and operator note.
4. A separate `NOT_FOUND_CONFIRMED` resolution that permits a retry only after a complete provider lookup; the retry must reuse the original idempotency key.
5. A dashboard/operator surface that shows charge ID, shop, amount, currency, idempotency key, attempt history and provider lookup evidence without exposing access tokens.

No operator action may accept an arbitrary shop/tenant pairing, overwrite a SUBMITTED charge, or replace the persisted idempotency key.

## Acceptance tests still required

- Shopify accepted the usage record but the HTTP response was dropped; the next reconciliation finds the exact idempotency key and commits SUBMITTED without a second mutation.
- Shopify did not accept the usage record; a complete lookup finds no match and a retry reuses the original idempotency key.
- Provider lookup times out or is rate-limited; HENVALT remains PENDING and sends no mutation.
- A key match with the wrong amount/currency/line item is rejected for operator review.
- Pagination crosses the original charge timestamp and does not falsely report NOT_FOUND.
- Two concurrent reconcilers cannot double-record or overwrite the charge.
- The operator resolution is tenant-bound, audited and cannot rewrite a submitted charge.

## Release boundary

This document does not deploy or call Shopify. The worker remains candidate code; the production project has no billing worker deployment or refund-credit-offset migration. The scheduler candidate remains inactive and uses an invalid staging hostname.
