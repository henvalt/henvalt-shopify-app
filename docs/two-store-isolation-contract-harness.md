# Two-store isolation contract harness

**Status:** synthetic executable contract tests; review-only.  
**Production data:** not copied or modified.  
**Production behavior:** not yet verified by these tests.

## Purpose

HENVALT must support two independent Shopify shops under one merchant tenant without treating tenant membership as proof that records belong to the same store. This harness makes the minimum security invariants executable using synthetic fixtures only.

Run locally with:

```bash
node --test tests/two-store-isolation-contract.test.mjs
```

## Synthetic fixture

- One shared tenant.
- Store A uses app key `legacy` and connection `connection-a`.
- Store B uses app key `public_v1` and connection `connection-b`.
- Both stores deliberately reuse the same Shopify customer ID, email, and session reference.
- Store B has a later order, intentionally testing whether Store A's recovery is incorrectly stopped or credited.

No production identifiers, customer records, email addresses, checkout IDs, tokens, or order payloads are included.

## Required invariants

| ID | Scenario | Required outcome |
|---|---|---|
| ISO-01 | Resolve by app key + normalized shop | Exactly one active connection |
| ISO-02 | Unknown app key or app/shop mismatch | Fail closed |
| ISO-03 | Duplicate app/shop matches | Reject as ambiguous |
| ISO-04 | Same external customer ID in two shops | Two distinct store-scoped identities |
| ISO-05 | Store B order after Store A opportunity | Must not stop Store A sequence |
| ISO-06 | Store B order against Store A opportunity | Must not receive Store A attribution |
| ISO-07 | Store A opt-out | Does not suppress Store B by default |
| ISO-08 | Missing connection lineage | Fail closed |

## Important limitation

These tests exercise a reference model of the required behavior. They do **not** prove the deployed PostgreSQL functions, n8n workflows, Cloudflare Worker, Edge Functions, or Shopify callbacks already enforce it. Production verification requires app-aware database writers and readers, connection-scoped foreign keys/lineage, then isolated database integration tests against synthetic records in a non-production environment.

## Current schema facts that motivate the harness

The live schema snapshot shows that key uniqueness constraints are tenant-scoped, not connection-scoped:

- `customers(tenant_id, shopify_customer_id)`
- `checkouts(tenant_id, shopify_checkout_id)`
- `checkouts(tenant_id, checkout_token)` (partial unique)
- `webhook_events(tenant_id, idempotency_key)`
- `webhook_events(tenant_id, source, source_event_id)`
- `canonical_events(tenant_id, idempotency_key)`
- `opportunities(tenant_id, idempotency_key)`
- `orders(tenant_id, shopify_order_id)`
- `delivery_requests(tenant_id, idempotency_key)`
- `recovery_interventions(tenant_id, idempotency_key)`

Some tenant-scoped keys may remain valid at tenant scope if upstream IDs are globally unique and lineage is proven. Shopify customer, checkout, session, and event identifiers must not be assumed globally unique across separate shops. A migration must first quantify collision groups using aggregate-only queries, then preserve historical rows while introducing typed connection lineage.

## Next implementation gate

Before writing a production migration, inspect every writer's `ON CONFLICT` target and all downstream readers. Any identity key that is shop-local must become connection-scoped (or use a composite key that includes the connection). Then build actual database integration tests in a disposable/non-production database. No production migration, deployment, workflow edit, or Shopify release is authorized by this artifact.
