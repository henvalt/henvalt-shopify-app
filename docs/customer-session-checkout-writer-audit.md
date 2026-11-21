# Customer, Session and Checkout Writer Audit

**Inspection date:** 2026-11-16  
**Environment:** live HENVALT Supabase function catalog/source and constraint inspection, read-only  
**Preparation branch:** `prep/public-app-hardening-2026-11-15`  
**Scope:** customer upsert, session alias binding, event identity resolution, checkout upsert  
**Safety:** no production function, table, row, migration, workflow, or deployment was changed.

## Executive result

The current deployed identity writers are tenant-scoped. Migration 007 adds nullable `shopify_connection_id` columns and store-qualified indexes, but deliberately leaves the old tenant-only unique constraints in place for V1 compatibility. Therefore those columns alone do not make the existing writers safe for a multi-store tenant.

The four inspected functions are:

- `upsert_customer(p_tenant_id, p_shopify_customer_id, ...)`
- `bind_session_alias(p_tenant_id, p_alias_reference, p_session_reference)`
- `resolve_identity(p_event_id)`
- `upsert_checkout(p_tenant_id, p_shopify_checkout_id, ...)`

None accepts an authoritative Shopify connection ID in its current signature.

## Confirmed deployed behavior

### Customer identity

`upsert_customer` searches by tenant plus Shopify customer ID. When the Shopify customer ID is null, it falls back to tenant plus case-insensitive email and selects the oldest match. It then updates the selected customer record.

Consequences:

- Two stores under one tenant that reuse a Shopify customer ID can resolve to the same customer.
- An event without a Shopify customer ID can be merged into another store's customer by email.
- Email is a contact attribute, not proof of Shopify store identity.
- The writer cannot populate the new connection column from a trusted argument because no such argument exists.

### Session and alias identity

`bind_session_alias` upserts sessions on `(tenant_id, session_reference)` and aliases on `(tenant_id, alias_reference)`. The deployed primary/unique constraints confirm those tenant-wide keys.

Consequences:

- Reused browser/session references or checkout aliases across stores can collide.
- A store-B checkout alias can be rejected as already bound to a store-A session, or can resolve against the wrong session.
- Adding a nullable connection column without changing the writer and uniqueness contract does not solve this.

### Event identity resolution

`resolve_identity(p_event_id)` reads tenant, customer reference, email, session reference and anonymous reference from a canonical event. It resolves customer by tenant + Shopify customer ID, then tenant + email; resolves aliases and sessions by tenant + reference; and finds a checkout by tenant + email/session reference.

Consequences:

- The resolver has no exact-store boundary even if the source event eventually has one.
- It can attach a canonical event to a customer, session, alias or checkout originating from another store in the same tenant.
- Consent-disabled events must not enter this identity fallback path with customer/session/checkout identifiers.

### Checkout identity

`upsert_checkout` has no connection argument. The live constraint inventory confirms a tenant-wide unique key on `(tenant_id, shopify_checkout_id)`. Migration 007 adds store-qualified indexes but intentionally preserves this legacy unique key.

Consequences:

- A reused checkout ID in a second store still collides with the legacy tenant-wide constraint.
- The current writer cannot safely use the new store-qualified index as its conflict target.
- Checkout token/session association also needs exact connection scope; metadata shop domain is not a substitute for a foreign key.

## Safe implementation decision

Do not retrofit these existing V1 functions in place yet. They are used by current production workflows, and changing their signatures/uniqueness behavior before all readers are updated risks breaking existing ingestion or causing old recovery consumers to process partially store-aware records.

The next implementation must use a staged V2 contract:

1. Resolve `shopify_connection_id` only from the verified webhook inbox or server-validated pixel-key mapping. Never accept it as a trusted browser field.
2. Require the exact connection to be active for new commercial event ingestion. Privacy requests are handled by their separate compliance path and must still resolve historical/uninstalled stores.
3. Key customers by `(shopify_connection_id, shopify_customer_id)`. Do not use email as an identity fallback. If no Shopify customer ID exists, keep the event's customer unresolved rather than merging by email.
4. Key sessions by `(shopify_connection_id, session_reference)` and aliases by `(shopify_connection_id, alias_reference)`. Bind an alias only to a session with the same connection.
5. Key checkouts by `(shopify_connection_id, shopify_checkout_id)`; qualify checkout tokens and session associations by the same connection.
6. Ensure customer, session, alias and checkout relationships use composite foreign keys including tenant and connection.
7. Keep historical rows with null connection unresolved. Do not backfill from email, raw session values, checkout tokens or mutable metadata.
8. Keep analytics-consent-disabled pixel events out of customer/session/checkout resolution entirely. Marketing consent does not imply analytics consent.
9. Do not publish V2 customer/session/checkout rows into legacy canonical/recovery readers until those readers enforce the same connection invariant.
10. Only after V2 writers and all readers are proven compatible should the tenant-only unique constraints be retired in a separately reviewed migration.

## Required two-store regression cases

A disposable PostgreSQL fixture must use two active Shopify connections under one tenant and deliberately reuse the same external values:

- same Shopify customer ID;
- same email with different Shopify customer IDs;
- missing Shopify customer ID with the same email;
- same session reference;
- same alias/checkout token;
- same Shopify checkout ID;
- same pixel event ID.

Expected behavior:

- Store A and Store B customers remain distinct by connection.
- Email never causes cross-store identity merging.
- Session and alias values resolve only within their source connection.
- Checkout IDs/tokens remain independent per connection.
- Exact retries within one store are idempotent.
- Same external ID with changed payload is rejected or quarantined according to the V2 writer contract.
- Consent-disabled events persist no customer, session, alias or checkout identity references.
- No V2 intake writes into legacy canonical events, opportunities, recovery sequences, delivery requests, attribution or billing before the connection-aware adapter exists.

## Explicit non-actions

This audit and contract are preparation-only. No V2 identity writer, new table, migration, or production function replacement was created in this stage. The existing V1 functions remain untouched. No live data was backfilled, and no Supabase migration, n8n workflow, Worker, Edge Function, Shopify setting or release was changed.
