# Verified Shopify order conversion projection V2

**Status:** branch-only candidate; migrations 001–022 passed disposable PostgreSQL CI run #293. Not applied or deployed.
**Depends on:** candidate migrations 001–021.

## Purpose

An order created after checkout must suppress further abandoned-checkout recovery. The 2026-04 Shopify webhook contract uses `checkout_token`, not the removed `checkout_id`. This adapter binds order and checkout by that token and exact Shopify connection.

## Flow

- The V2 ingress first verifies the Shopify raw-body HMAC and stores an exact-store delivery receipt.
- For `orders/create`, `orders/updated`, `orders/paid` and `orders/cancelled`, the Edge Function sends the same raw bytes to `project_verified_shopify_order_v2`. Migration 021 replaces the original create-only topic gate; order status and cancellation timestamps are upserted by exact connection + order ID.
- The RPC resolves the installation from the hashed route token, verifies the receipt's raw-body digest, and refuses inactive app/connection/tenant or wrong topic.
- It stores a minimal order identity record keyed by (connection, Shopify order ID).
- If the payload contains `checkout_token`, it marks only the checkout with the same token on the same connection as COMPLETED.
- If no checkout record exists yet, the order is recorded as `CHECKOUT_NOT_FOUND`; no cross-store or fuzzy match is attempted.
- If the order has no checkout token, it is recorded as `NO_CHECKOUT_TOKEN` and does not mutate any checkout.
- SQL integration tests cover paid and cancelled updates while preserving the existing exact-store checkout lineage.
- Customer identity references are pseudonymous and exact-store scoped. No email, phone, address, line items or raw body are stored.

## Boundaries

- No legacy `orders`, `checkouts`, `customers`, `canonical_events`, recovery or billing table is written.
- Existing tenant-only order uniqueness and V1 functions are unchanged.
- A checkout webhook arriving after its order will require a follow-up reconciliation adapter; this migration does not infer or backfill an order-to-checkout relation.
- Migration 022 adds an exact-store refund adjustment ledger from successful refund transactions, validates transaction currency against the matched order, and updates partial/full refund financial status. CI #293 passed duplicate-delivery and cumulative-refund tests. Order transaction events remain inbox-only; refund-aware attribution still needs a policy and fee ledger.
- The V2 order table is not yet consumed by a recovery candidate reader. That reader must require exact connection lineage and should treat an order with a matching checkout token as conversion suppression.
