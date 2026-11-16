# Connection-aware database migration dependency map

Status: design-only engineering artifact. Based on read-only live catalog inspection on 2026-11-16. No DDL or data changes are included or applied.

## 1. Verified schema prerequisites

### Connection table
Live `henvalt.shopify_connections` currently has:
- Primary key: `(id)`
- Unique: `(shop_domain)`
- Unique: `(tenant_id, shopify_shop_id)`
- Foreign key: `tenant_id -> tenants(id)`
- No verified unique constraint on `(tenant_id,id)`
- No `app_key` column in the inspected table definition.

**Migration prerequisite:** add/validate a unique target on `(tenant_id,id)` before creating composite foreign keys from tenant-owned rows. The target is logically redundant because `id` is already globally unique, but PostgreSQL requires a matching unique referenced key for a composite FK. Preserve `UNIQUE(shop_domain)` for the first public rollout.

### OAuth state
Live `shopify_oauth_states` is keyed by `state_hash`; it contains `shop_domain`, expiry, consumed timestamp, correlation ID and initiating user. It has no app key or callback route. The current finalizer takes state hash and shop domain, but no app key or connection ID.

**Migration prerequisite:** app identity must be attached to the OAuth state before the callback chooses credentials. Existing finalizer remains legacy-only. The new finalizer must validate and lock the state, resolve the app registry entry, check same-shop app conflict, and only then write Vault token references to the exact connection.

## 2. Existing relationship gaps

The live catalog confirms that the following source records currently carry tenant identity but no typed Shopify connection identity:
- `webhook_events`
- `canonical_events`
- `customers`
- `checkouts`
- `sessions`
- `opportunities`
- `orders`

Their current external identity uniqueness is tenant-scoped (for example customer ID, checkout ID/token, session reference, webhook event/idempotency keys, canonical idempotency key, opportunity idempotency key, and order ID).

The current FK graph mostly enforces individual row references, not same-tenant-and-same-store references. Examples confirmed in the catalog:
- checkout.customer_id -> customers.id (single-column FK);
- opportunity.customer_id -> customers.id, checkout_id -> checkouts.id, source_event_id -> canonical_events.id (single-column FKs);
- order.customer_id -> customers.id and checkout_id -> checkouts.id (single-column FKs);
- recovery sequence -> opportunity; intervention -> sequence and opportunity;
- delivery request -> intervention, opportunity and sequence/recovery references;
- attribution -> order, opportunity, recovery and intervention;
- revenue ledger -> order, attribution, opportunity and recovery.

The parent and child rows have tenant_id columns, but these individual foreign keys do not prove that the linked rows share the same tenant, much less the same Shopify connection. Composite tenant+parent foreign keys are required to enforce that lineage in the database.

## 3. Recommended additive dependency order

This is the dependency order for design and implementation, not a ready-to-run migration.

| Stage | Tables / objects | Required work | Gate before next stage |
|---|---|---|---|
| 0 | catalog, policies, functions | Snapshot exact schema, RLS, grants, triggers, overloads, writer bodies and current indexes | Inventory signed off; no assumptions from metadata |
| 1 | app registry, shopify_oauth_states | Introduce app-key registry and persist app_key/callback route on OAuth state | Callback can identify app without trusting request headers |
| 2 | shopify_connections | Add app_key; add unique (tenant_id,id) target; preserve unique shop_domain | Legacy rows explicitly mapped only after provenance verification |
| 3 | webhook_events | Add nullable connection ID; add tenant+connection composite FK; update ingress writer and event uniqueness strategy | HMAC verified and exact connection resolved before persistence |
| 4 | canonical_events | Add nullable connection ID; composite FK; enforce same connection as webhook receipt when present | Webhook-to-canonical lineage is exact |
| 5 | customers, sessions, aliases | Add nullable connection ID; add composite tenant+connection FK; design per-connection external keys and email fallback | No cross-store customer/session merges |
| 6 | checkouts | Add nullable connection ID; scope checkout ID/token; enforce customer same-connection relationship | Checkout event, customer and session identity agree |
| 7 | opportunities | Add nullable connection ID; enforce source event, customer and checkout connection equality; revise idempotency | Candidate creation cannot cross stores |
| 8 | orders | Add nullable connection ID; enforce customer/checkout/source event lineage; revise external order key | Order projection has one exact connection |
| 9 | recovery_sequences, recovery_interventions | Inherit connection from opportunity; composite parent FKs; revise idempotency and sequence constraints only where required | Recovery worker context returns validated connection |
| 10 | delivery_requests, delivery_attempts, customer_conversations, conversation_messages | Inherit and enforce exact connection through intervention/opportunity/recovery; preserve opaque reply token uniqueness | Authorization and reply routing cannot cross stores |
| 11 | order_attributions, revenue_ledger | Enforce order/opportunity/recovery same-connection lineage before attribution or billable ledger entry | Cross-store attribution and charges are impossible |
| 12 | consent, suppressions, privacy and billing readers | Add explicit store-vs-tenant policy and scope all RPCs/readers accordingly | Privacy, unsubscribe, dashboard and billing acceptance tests pass |
| 13 | constraints and legacy compatibility | Dual-write/read-compare, collision review, synthetic tests, then staged unique-index cutover | Rollback path tested; no unresolved cross-store rows |

## 4. Composite FK pattern (illustrative only)

The intended relationship shape is:

- Parent row has `UNIQUE(tenant_id,id)`.
- Child row carries both `tenant_id` and the parent's UUID.
- Child declares `FOREIGN KEY (tenant_id,parent_id) REFERENCES parent(tenant_id,id)`.

For Shopify source rows, the same pattern applies to `(tenant_id,shopify_connection_id)` referencing `shopify_connections(tenant_id,id)`.

This document intentionally does not include executable `ALTER TABLE` statements. Exact constraint names, nullability, delete behavior, existing orphan rows and index-build strategy must be confirmed table by table before writing migration SQL.

## 5. Writer-specific findings verified from live function catalog

- `upsert_customer`: one live function signature; body 45,528 characters; no literal `ON CONFLICT` clause found. Must inspect its full read-before-write and update path, not assume conflict handling is absent.
- `upsert_checkout`: one live signature; body 65,647 characters; contains `ON CONFLICT (tenant_id, shopify_checkout_id)`. That target cannot support two stores under one tenant without a staged uniqueness migration and revised writer.
- `upsert_canonical_event`: one live signature; body 18,706 characters; no literal `ON CONFLICT` clause found. Its lookup/update logic still requires full-path inspection.
- `project_order_from_event`: one live signature; body 4,844 characters; no literal `ON CONFLICT` clause found. It must be updated to require source-event connection identity and same-connection customer/checkout resolution.
- `control_plane_connect_shop`: one live signature; shop-domain based; no app key.
- `control_plane_finalize_shopify_oauth_install_expiring_for_owner`: one live signature; takes state hash/shop domain and tokens, no app key or connection ID. Its only ON CONFLICT in the inspected body is tenant_memberships (tenant_id,user_id), unrelated to store identity.

## 6. Stop conditions

Do not proceed to executable DDL until:
1. Every FK path has a same-tenant/same-connection design, including nullable historical lineage.
2. Every writer's full body and all update/insert branches are reviewed.
3. Every RLS policy, service-role function and edge caller has an explicit trust boundary.
4. Existing rows are classified as trusted, legacy-only or ambiguous; no inferred backfill from untrusted metadata.
5. Consent/suppression and billing principal are explicitly decided.
6. Two-store synthetic tests prove isolation for reused customer IDs, email, checkout IDs/tokens, sessions, event IDs, order IDs, replies, opt-outs, privacy deletion and billing.

## 7. Safety boundary

Read-only catalog inspection only. No Supabase DDL/DML, migration apply, function replacement, Worker/Edge Function deployment, n8n edit, Shopify release, PR merge or production change occurred.
