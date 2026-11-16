# Exact-Store Identity — Live Constraint Inventory

**Inspection date:** 2026-11-16  
**Environment:** connected HENVALT Supabase project; read-only catalog query  
**Status:** evidence and implementation design only  
**Production changes:** none

## Executive result

A read-only inspection of the deployed PostgreSQL constraints confirms that several Shopify-originated identities are unique only within a HENVALT tenant. That is insufficient when one tenant has more than one Shopify store.

This is not just a missing-column problem. Writers, foreign keys, uniqueness rules, readers, recovery decisions, attribution, suppression and privacy operations must all agree on the same immutable Shopify connection.

## Verified live uniqueness constraints

| Table | Current unique key | Store-safe requirement |
|---|---|---|
| `customers` | `(tenant_id, shopify_customer_id)` | `(tenant_id, shopify_connection_id, shopify_customer_id)` |
| `checkouts` | `(tenant_id, shopify_checkout_id)` | `(tenant_id, shopify_connection_id, shopify_checkout_id)` |
| `orders` | `(tenant_id, shopify_order_id)` | `(tenant_id, shopify_connection_id, shopify_order_id)` |
| `sessions` | `(tenant_id, session_reference)` | `(tenant_id, shopify_connection_id, session_reference)` |
| `session_aliases` | primary key `(tenant_id, alias_reference)` | `(tenant_id, shopify_connection_id, alias_reference)` |
| `canonical_events` | `(tenant_id, idempotency_key)` | connection-qualified idempotency; retain legacy constraint until all writers are migrated |
| `webhook_events` | `(tenant_id, idempotency_key)` and `(tenant_id, source, source_event_id)` | connection-qualified delivery/event identity in the new inbox; legacy table remains unchanged until adapter cutover |
| `opportunities` | `(tenant_id, idempotency_key)` | connection-qualified idempotency |
| `recovery_interventions` | `(tenant_id, idempotency_key)`; `(tenant_id, sequence_id, step_number)` | inherit and enforce the exact connection from opportunity/sequence |
| `delivery_requests` | `(tenant_id, idempotency_key)` | inherit and enforce the exact connection from the full recovery lineage |

Other inspected relationships are mostly single-column foreign keys or tenant-scoped composite relationships. For example, checkouts reference customers by customer UUID only; opportunities reference customer, checkout and source event by UUID only; recovery sequences and interventions use tenant/opportunity or tenant/sequence relationships; delivery requests refer to intervention, opportunity and recovery IDs without a shared connection constraint.

## Additional verified structural facts

- `pixel_keys.shopify_connection_id` already exists and is non-null, with an FK to `shopify_connections(id)`. This is the trusted store identity at the pixel-key boundary.
- The deployed pixel ingestion function resolves the key against the connection but currently retains only the tenant ID before calling the canonical event writer. The connection identity is discarded before durable event storage.
- `shopify_connections.shop_domain` is globally unique today. This does not make downstream tenant-scoped customer, checkout, session or event identities store-safe.
- `shopify_connections` also has a tenant + Shopify shop ID unique constraint. That constraint is not a substitute for connection lineage on business records.
- `customer_conversations` has tenant-scoped relationships and a unique `(tenant_id, delivery_request_id)`; `conversation_messages` references its conversation by `(tenant_id, conversation_id)`. These need the connection to be inherited and validated through their parent lineage, not guessed from email.
- `provider_events` is globally unique by `(provider, event_hash)` and has no Shopify connection field. Provider event identity should remain provider-scoped; the linked delivery request must carry the validated store lineage.
- `email_suppressions` is tenant-scoped and has no explicit store/policy dimension. This requires an explicit product policy decision in implementation; it must not silently infer tenant-wide consent from a store-level Shopify action.
- `unsubscribe_tokens` has tenant + customer references and stores the originating intervention only in metadata. A future token contract must carry an immutable originating connection and explicit suppression scope.
- The live `shopify_privacy_requests` table has tenant/shop-domain/shop-ID fields but no exact connection/app foreign key. The new V2 privacy inbox remains the separate verified receipt path and review-gated.

## Why we must not simply drop the old unique constraints

Dropping tenant-level uniqueness before all writers are connection-aware would weaken existing behavior and could permit duplicates from legacy paths. Conversely, retaining only the tenant-level unique key can collapse distinct Store A and Store B identities when they reuse the same external ID.

The safe migration sequence is therefore:

1. Add nullable connection lineage and composite parent keys as additive schema changes.
2. Introduce new V2 writers that resolve connection identity only from trusted server-side sources (verified webhook inbox, app-aware OAuth connection, or stored pixel-key relationship).
3. Add connection-qualified uniqueness for newly verified rows and make the new writer use those keys.
4. Keep legacy writer contracts and historical rows intact during shadow comparison; unresolved historical rows remain NULL and ineligible for store-specific recovery or billing.
5. Add exact-store read paths for candidate discovery, recovery context, delivery authorization, attribution, billing, consent and privacy.
6. Prove two-store behavior with deliberately reused Shopify customer IDs, checkout IDs/tokens, session references, event IDs and email addresses.
7. Only after every writer and reader is migrated should a separate reviewed migration retire or replace legacy tenant-only uniqueness where appropriate.

## Non-negotiable invariants

- Never accept `tenant_id`, `shopify_connection_id` or `app_key` from an untrusted storefront event as the source of truth.
- Never use email, customer ID, checkout token, session reference, metadata shop domain, current pixel-key state, tenant membership or timestamp alone to infer historical store ownership.
- Every Shopify-originated event must resolve to exactly one app + connection + tenant before it can create or advance recovery.
- Every recovery chain must have one consistent connection from source event through customer/checkout/opportunity/sequence/intervention/delivery/conversation/tracking/attribution.
- A missing, inactive, ambiguous or conflicting connection must fail closed.
- A store-level privacy request must never delete another store or the whole tenant.
- Shared provider configuration may remain tenant-scoped only where that is the explicit account policy; it must not be used to infer Shopify store ownership.

## Verification boundary

This inventory was gathered with SELECT-only PostgreSQL catalog queries against the connected project. It inspected column definitions and primary-key, unique and foreign-key definitions; it did not read customer rows, payloads, email addresses, secrets or access tokens.

No production DDL/DML, backfill, function replacement, migration apply, n8n edit, Worker/Edge deployment, Shopify configuration change or release occurred. This file is a branch-only evidence artifact and does not make the application multi-store safe by itself.
