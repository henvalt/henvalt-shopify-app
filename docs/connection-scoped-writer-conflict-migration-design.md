# Connection-scoped identity: writer conflict and migration design

Status: engineering design only; not an executable migration. Live schema inspected read-only on 2026-11-16.

## Verified live unique indexes

The following definitions were returned by `pg_indexes` in schema `henvalt`:

| Table | Unique index | Current key |
|---|---|---|
| customers | customers_tenant_id_shopify_customer_id_key | tenant_id, shopify_customer_id |
| checkouts | checkouts_tenant_id_shopify_checkout_id_key | tenant_id, shopify_checkout_id |
| checkouts | checkouts_tenant_checkout_token_unique | tenant_id, checkout_token WHERE checkout_token IS NOT NULL |
| sessions | sessions_tenant_id_session_reference_key | tenant_id, session_reference |
| webhook_events | webhook_events_tenant_id_idempotency_key_key | tenant_id, idempotency_key |
| webhook_events | webhook_events_tenant_id_source_source_event_id_key | tenant_id, source, source_event_id |
| canonical_events | canonical_events_tenant_id_idempotency_key_key | tenant_id, idempotency_key |
| opportunities | opportunities_tenant_id_idempotency_key_key | tenant_id, idempotency_key |
| orders | orders_tenant_id_shopify_order_id_key | tenant_id, shopify_order_id |

The tables also have their ordinary primary-key indexes. No connection-scoped unique key was found in this inspected set.

## Core conclusion

A connection ID column by itself does not create isolation. Writers must derive a trusted connection identity from authenticated app identity + normalized shop domain, carry it through source events and derived records, and use conflict targets consistent with that identity. Every reader, resolver, suppression path, conversion check, attribution path and deletion path must use the same lineage.

Do not replace the existing unique indexes until the new identity is populated, validated, and all writers have been migrated in a controlled dual-write/read-compare sequence.

## Required writer changes

### Customers
- Resolve the exact active connection before customer upsert.
- Introduce a nullable `shopify_connection_id` with a composite tenant+connection FK.
- New records use a connection-scoped identity key: `(tenant_id, shopify_connection_id, shopify_customer_id)`.
- Email fallback must be explicitly scoped to the same connection. Do not silently merge same-email customers across stores.
- Keep legacy lookup behavior for legacy-only traffic during the compatibility window; fail closed if a request's app/shop identity is ambiguous.

### Checkouts
- Resolve the checkout's source connection from the authenticated webhook or pixel provenance, not client-supplied metadata alone.
- Scope Shopify checkout ID and checkout-token uniqueness to the connection.
- A checkout token is not globally unique and must never be used to bridge two connections.
- Carry the exact connection through checkout-to-opportunity and checkout-to-order projection.

### Sessions and aliases
- Scope session references and aliases by connection.
- A browser/session identifier reused in another shop must create an independent identity.
- Ensure cart/browse candidate discovery and suppression checks include connection identity.

### Webhook and canonical events
- Resolve app key + normalized shop domain before event persistence.
- Persist the exact connection ID on the webhook receipt and canonical event.
- Idempotency keys become connection-scoped; source event IDs are not assumed globally unique across shops.
- Reject unknown app keys, inactive connections, ambiguous shop resolution and unsigned identity headers.

### Opportunities and orders
- Derive connection from the immutable source-event/checkout lineage.
- Reject mismatches between event, customer, checkout, opportunity and order.
- Use connection-scoped external identifiers and idempotency keys.
- Revenue attribution must verify that order and opportunity share the same exact connection before any amount is considered recoverable or billable.

## Additive migration sequence (not applied)

1. **Preflight:** snapshot current index definitions, table row counts, nullability, FK targets, function signatures, RLS/grants and duplicate normalized shop domains. Do not export customer PII.
2. **Connection target:** add/verify a unique target on `shopify_connections(tenant_id,id)` before adding composite foreign keys. Preserve existing shop-domain uniqueness for the first public rollout.
3. **Nullable columns:** add nullable `app_key` to app registry / OAuth state / connection and nullable `shopify_connection_id` to source and derived records in dependency order. No automatic backfill.
4. **Trusted ingress:** app-aware OAuth state, webhook HMAC verification and exact connection resolution must be deployed before accepting public-app events.
5. **Dual write:** write the new connection ID while preserving legacy columns and current indexes. Compare old and new resolution results without changing delivery or billing decisions.
6. **Reader migration:** update every candidate, worker, delivery authorization, consent, unsubscribe, privacy, attribution, billing and dashboard reader to enforce the same connection lineage.
7. **Collision review:** quantify key collisions and historical ambiguity by aggregate-only queries. Historical rows lacking reliable provenance remain quarantined/legacy-only; never infer store identity from tenant, active connection count, email, timestamps, or a shop-domain hint that was not authenticated.
8. **Synthetic regression:** run two-store fixtures with deliberately reused Shopify customer IDs, emails, checkout IDs/tokens, session IDs, order IDs, source event IDs and idempotency keys. Include conversion, opt-out, unsubscribe, privacy deletion and billing assertions.
9. **Constraint cutover:** only after all writers/readers pass, introduce connection-scoped unique indexes and switch conflict targets. Retain rollback compatibility until post-cutover verification completes.

## Non-negotiable failure behavior

- Missing, unknown, disabled or ambiguous app identity: reject; no legacy fallback.
- A shop already connected to another HENVALT app identity: reject before any token/Vault write.
- Missing or conflicting connection lineage: no recovery send, no attribution credit, no billable recovered revenue.
- Historical record with uncertain store provenance: quarantine or preserve under explicitly legacy-only semantics; never guess.
- Store-redact: delete only the exact store's data according to retention policy; never delete the whole tenant because one store uninstalled.

## Validation still required

- Inspect every overload and full body of the live writer functions, including exact `ON CONFLICT` clauses and all read-before-write queries.
- Inventory unique and non-unique indexes for aliases, carts, pixel events, deliveries, conversations, attribution, ledger and provider events.
- Confirm the actual table/column graph and FK constraints before authoring executable DDL.
- Test service-role/security-definer behavior and RLS grants with composite FKs.
- Decide store-level vs tenant-level billing explicitly; this design does not decide it.

## Safety boundary

This document records a proposed implementation. It is not a migration and contains no production SQL to apply. No live database, Shopify app, Worker, Edge Function or n8n workflow was changed during this audit.
