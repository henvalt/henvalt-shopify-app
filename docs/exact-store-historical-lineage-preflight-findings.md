# Exact-Store Historical Lineage Preflight — Live Read-Only Findings

**Inspection date:** 2026-11-16
**Project:** connected HENVALT Supabase project
**Method:** read-only catalog inspection and aggregate-only SELECT diagnostics
**Preparation branch:** `prep/public-app-hardening-2026-11-15`
**Safety:** no production rows, schema, functions, credentials, or settings were changed. No personal values, shop domains, tokens, or secret values were returned in the diagnostics.

## 1. Executive finding

The first aggregate preflight shows that the live project is small enough for a careful, staged migration, but historical store lineage is already incomplete. The main blocker is not row volume; it is provenance.

- There are 4 active Shopify connections across 3 tenants. One tenant has multiple stores.
- There are 132 webhook receipts and 166 canonical events.
- 130 webhook receipts have a `metadata.shop_domain` value that matches exactly one current connection by normalized domain. Two webhook receipts do not have a usable matching domain under this check (one missing/unresolved and one? See the exact aggregate below: 130 with domain and 130 unique; total webhook rows 132, therefore 2 are not uniquely resolved).
- 131 canonical events reference a webhook receipt. Of those, 130 inherit a unique *metadata-domain candidate* through the parent receipt; one does not.
- 35 canonical events have no webhook parent. All 35 are `SHOPIFY_WEB_PIXEL` events (19 PAGE_VIEWED, 6 PRODUCT_ADDED_TO_CART, 10 PRODUCT_VIEWED).
- The deployed `henvalt.ingest_pixel_event` function validates the pixel key against an active `pixel_keys` → `shopify_connections` relationship, but selects only `pk.tenant_id` into its local context. It then calls `upsert_canonical_event` with a NULL webhook parent and does not persist `pk.shopify_connection_id` on the canonical event. The trusted connection is therefore discarded at the point of ingestion.
- The 35 existing pixel events cannot be safely assigned to a store merely because only one pixel key is currently active. There are 16 pixel key records in total, only 1 currently active and not revoked. Current key state does not prove which key accepted each historical event.
- The 2 checkout rows and 3 opportunity rows are small in count; their metadata contains a shop-domain key in only one checkout and three opportunities. Metadata matching is useful for investigation but is not a typed immutable FK.
- No duplicate groups were found for the sampled current tenant-scoped identity/idempotency keys (customer Shopify ID, checkout ID/token, order ID, session reference, webhook/canonical/opportunity/intervention idempotency). This does **not** prove there were no cross-store collisions: existing tenant-scoped unique constraints and ON CONFLICT writers can collapse or overwrite evidence before a duplicate can exist.

## 2. Aggregate counts observed

| Table | Rows |
|---|---:|
| shopify_connections | 4 |
| shopify_oauth_states | 30 |
| webhook_events | 132 |
| canonical_events | 166 |
| pixel_keys | 16 |
| customers | 3 |
| sessions | 5 |
| session_aliases | 2 |
| checkouts | 2 |
| orders | 0 |
| opportunities | 5 |
| recovery_sequences | 3 |
| recovery_interventions | 5 |
| delivery_requests | 3 |
| delivery_attempts | 5 |
| customer_conversations | 0 |
| conversation_messages | 0 |
| order_attributions | 0 |
| revenue_ledger | 0 |
| email_usage_measurements | 4 |
| shopify_privacy_requests | 0 |
| unsubscribe_tokens | 7 |
| email_suppressions | 0 |

Connection summary: 4 total connections, all 4 active; 1 tenant has more than one connection. Pixel key summary: 16 total, 1 active and not revoked.

## 3. Webhook receipt lineage

The diagnostic checked whether each webhook receipt's stored `metadata.shop_domain` resolves to exactly one current `shopify_connections.shop_domain`.

Observed:
- 130 webhook rows have a non-empty stored shop domain.
- All 130 of those domains match exactly one current connection.
- Total webhook rows are 132, so 2 rows do not have a unique domain match under this metadata-only check.
- 131 canonical events reference webhook receipts.
- 130 of those canonical rows inherit a unique domain-match candidate from the parent receipt; 1 does not.
- No canonical row with a non-null webhook_event_id had a missing parent or tenant mismatch in the FK consistency check.

**Important trust qualification:** this is a structural metadata-resolution result, not cryptographic proof that the stored shop domain is authentic. Shopify's HMAC authenticates the raw body; a shop-domain HTTP header is not part of that body HMAC. A replayed valid body/signature with altered routing headers must be considered in the threat model. Do not backfill a typed connection ID solely from `metadata.shop_domain` until the ingress chain proves the domain is bound to the verified app/connection identity and replay semantics.

## 4. Pixel source lineage — confirmed loss point

The deployed `henvalt.ingest_pixel_event(p_key_digest, p_origin, p_payload)` function body was inspected read-only.

It:
1. Validates the digest shape, origin, payload size and event fields.
2. Joins `pixel_keys` to `shopify_connections` by `shopify_connection_id`, checks tenant equality, active connection, active/unrevoked key, allowed origin and active tenant.
3. Selects only `pk.tenant_id` into `v_tenant_id`.
4. Calls `upsert_canonical_event` with `webhook_event_id = NULL` and tenant ID, but no connection ID.
5. Resolves identity using the resulting canonical event ID.

This means the trusted pixel-key connection is available at verification time but not retained on the canonical event. The 35 historical pixel events are consequently tenant-scoped only. The safe correction is to add an app/store-aware pixel ingestion writer that passes the validated connection ID through the canonical event insert and rejects any mismatch; do not rewrite the current function in production as part of this preparation.

## 5. Historical backfill classification

| Source class | Current evidence | Backfill decision |
|---|---|---|
| Webhook receipt with exactly one metadata domain match | 130 rows | Candidate only; do not backfill until signed-app + shop routing trust is proven and replay tests pass |
| Webhook receipt without unique metadata match | 2 rows | Keep unresolved / NULL; never guess |
| Canonical event with webhook parent and unique parent domain match | 130 rows | Candidate only, inherits same trust caveat as parent |
| Canonical event with webhook parent but no unique parent match | 1 row | Keep unresolved / NULL |
| Pixel canonical event without webhook parent | 35 rows | Keep unresolved / NULL; historical pixel-key digest is not retained on the canonical row |
| Existing pixel_keys | 16 rows, 1 active | Preserve existing FK; current active key does not establish historical event provenance |
| Checkouts / opportunities with shop-domain metadata | 1 checkout / 3 opportunities have the key | Candidate evidence only; metadata is not a typed FK and requires parent-source reconciliation |
| Customer/session/order/recovery descendants | No typed connection lineage in current contract | Derive only through verified parent chain; otherwise quarantine |

Never backfill app_key from the currently configured secret, one active app, or the current connection alone. App identity provenance is a separate requirement from shop connection provenance.

## 6. Collision preflight interpretation

The aggregate query found zero duplicate groups for the currently constrained tenant-scoped keys tested:
- customer + Shopify customer ID;
- checkout + Shopify checkout ID;
- checkout + checkout token;
- order + Shopify order ID;
- session + session reference;
- webhook + idempotency key;
- canonical event + idempotency key;
- opportunity + idempotency key;
- intervention + idempotency key.

This is a baseline, not a green light to change unique indexes. A tenant-scoped unique key can prevent two stores in the same tenant from retaining the same external ID, and an `ON CONFLICT` writer may update the existing row. Therefore zero duplicate groups does not prove store isolation or absence of historical overwrite. Before changing any conflict target, inspect every writer and use synthetic two-store fixtures.

## 7. Migration sequencing adjustment

The database plan must be split into two independent provenance tracks:

**Track A — webhook path**
- Verify app identity selection, raw-body HMAC, shop routing, header trust and replay behavior.
- Only after that, attach the exact connection to the webhook receipt.
- Canonical events inherit connection from their exact webhook parent.
- Downstream descendants inherit through verified parent relations.

**Track B — pixel path**
- Resolve pixel digest to an active key and exact connection.
- Persist the connection ID on the canonical event in the same transaction as ingestion.
- Preserve pixel-key FK lineage; do not trust client payload to choose tenant or connection.
- Historical pixel events remain unresolved unless immutable server-side evidence independently identifies the original key/connection.

Then proceed to customer, session, checkout, order, opportunity, recovery, delivery, conversation, attribution, privacy and billing lineage in dependency order.

## 8. Reproducible read-only SQL

The aggregate-only diagnostic is saved at:
`docs/sql/exact-store-lineage-preflight-read-only.sql`

It emits only table counts, resolution counts and duplicate-group counts. It does not select customer values, shop domains, tokens, payload bodies, secret values, or identifiers. It contains no DDL/DML and is not a migration.

## 9. Explicit non-actions

No production migration was applied. No rows were backfilled, altered, or deleted. No function, trigger, policy, grant, or index was changed. No Worker, Edge Function, n8n workflow, or Shopify app was deployed or released. The preparation PR remains open, draft, and unmerged.
