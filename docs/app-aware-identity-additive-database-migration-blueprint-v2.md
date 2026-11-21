# HENVALT app-aware identity: additive database migration blueprint v2

**Status: engineering design / review-only. Not executable. Not applied to Supabase.**
**Scope:** prepare the first public-app rollout while preserving the existing merchant-owned app and its live credentials.
**Source of truth:** read-only catalog inspection of the connected Supabase project on 2026-11-16, plus the existing app-aware identity ADR and implementation contract.

## 1. Decision summary

The first public rollout must support multiple Shopify stores inside one HENVALT tenant, while allowing only one HENVALT app identity per Shopify shop. The current global unique key on shopify_connections.shop_domain remains in place for this rollout. A second HENVALT app trying to connect an already-connected shop must fail before any Vault write, token update, or reactivation.

The identity that must be carried end-to-end is:

app_key + shopify_connection_id + tenant_id + normalized_shop_domain

The shop domain is a lookup attribute, not a substitute for a typed connection ID. A tenant ID alone is never sufficient to authorize cross-store recovery, privacy, consent, or attribution operations.

No legacy app key may be backfilled from “only one app is currently configured”, active status, shop domain alone, or a Worker secret. Legacy provenance must be established from immutable, independently verifiable records; unresolved rows stay NULL/quarantined and are not eligible for the new public path.

## 2. Live catalog facts verified

The following were observed using read-only catalog queries:

- shopify_connections has UUID primary key id, tenant_id, globally unique shop_domain, shopify_shop_id, access/refresh Vault reference columns, token lifecycle fields and active.
- The connection table does not currently have app_key.
- shopify_oauth_states uses state_hash as its primary key and stores shop_domain, created_at, expires_at, consumed_at, correlation_id, and initiated_by_user_id; it has no app_key or callback-route identity.
- webhook_events contains tenant_id, Shopify source/topic/event ID, idempotency key, payload, status and metadata; it has no typed connection ID.
- canonical_events contains tenant_id and optional webhook_event_id; it has no typed connection ID.
- pixel_keys already contains shopify_connection_id and has a foreign key to shopify_connections(id). Preserve this existing typed binding.
- shopify_connections currently has 4 rows across 3 tenants in the earlier aggregate inspection; one tenant has two active store connections. This proves tenant != store, but does not justify any legacy app-key inference.
- Inspected writer RPC signatures for customer, checkout, canonical-event and order projection operations accept tenant-scoped identity but no connection ID.
- Existing idempotency and unique constraints are tenant-scoped (examples: customers by tenant/customer ID; checkouts by tenant/Shopify checkout ID and tenant/checkout token; orders by tenant/Shopify order ID; canonical events by tenant/idempotency key; opportunities by tenant/idempotency key). Do not change these conflict targets until every writer and collision set is reviewed.
- Existing RLS is enabled on the identity anchor/source tables. Do not force RLS or broaden table grants as part of this migration.

## 3. Stage A — app registry

Proposed new table: henvalt.shopify_app_registry.

Required logical fields:

| Field | Contract |
|---|---|
| app_key | Stable primary key such as legacy or public_v1; not the Shopify client ID |
| shopify_client_id | Unique non-secret Shopify client identifier |
| distribution_type | Explicit distribution mode, e.g. custom/merchant-owned or public |
| client_secret_vault_ref | Reference to secret storage only; never plaintext |
| active | Server-side enable/disable switch |
| created_at, updated_at | Audit timestamps |

Constraints and controls:
- Only a trusted server-side provisioning path may create/update registry rows.
- No anon/authenticated table access. Do not expose secret references through merchant APIs.
- Registry lookup must return a disabled/unknown result for absent or inactive keys.
- Never accept client ID, app key, secret reference, or distribution mode from an unsigned webhook header as trusted identity.
- Do not insert a legacy row until the current app's exact client ID and secret provenance have been verified by an authorized operator.

## 4. Stage B — OAuth and connection identity

Add nullable app_key to:
- shopify_connections
- shopify_oauth_states

Add a foreign key from each nullable app_key to the registry. Preserve the existing shop-domain unique constraint and OAuth state hash primary key.

For shopify_connections, add a unique constraint on (tenant_id, id) to make composite tenant+connection foreign keys possible. The UUID primary key remains unchanged.

OAuth state creation must persist the selected app key and trusted callback route at state creation time. Callback processing must:
1. Validate state hash, expiry and one-time consumption.
2. Read app key from the persisted state, never infer it from query parameters or the shop header.
3. Load the matching active registry entry and secret reference.
4. Verify callback HMAC and exchange code with that app's credentials.
5. Resolve any existing shop connection and reject a different app key before any Vault write or token mutation.
6. Bind the exact connection ID to the OAuth finalizer and token storage.
7. Consume state atomically so replay cannot create or mutate a connection.

Legacy finalizer remains legacy-only. The public callback must use a new app-aware finalizer; do not change the meaning of the old RPC.

## 5. Stage C — source receipt identity

Add nullable shopify_connection_id to:
- webhook_events
- canonical_events

Add unique parent targets (tenant_id,id) on webhook_events and preserve existing primary keys and unique idempotency constraints. Add composite foreign keys:
- webhook_events(tenant_id, shopify_connection_id) → shopify_connections(tenant_id,id)
- canonical_events(tenant_id, shopify_connection_id) → shopify_connections(tenant_id,id)
- canonical_events(tenant_id, webhook_event_id) → webhook_events(tenant_id,id) (after verifying and reconciling the existing single-column FK)

The canonical writer must inherit the connection ID from the exact webhook receipt when webhook_event_id is present. A supplied connection ID is a consistency assertion; mismatch rejects. Pixel-origin canonical events inherit the connection ID from the validated pixel_keys row. The client/pixel payload cannot choose its own tenant or connection.

The webhook Worker route must select app credentials from a static server-side route mapping, verify HMAC against raw request bytes, strip untrusted identity headers, and pass an authenticated identity envelope. Supabase verifies the HMAC again and resolves exact (app_key, normalized_shop_domain) to one active connection. Zero, multiple, inactive or conflicting matches fail closed.

## 6. Stage D — source-to-recovery identity graph

Do not add every column in one migration. Add nullable connection IDs in dependency order, dual-write and compare before any reads depend on them.

| Layer | Tables / records | Trusted source |
|---|---|---|
| Ingress | webhook_events, pixel receipt / canonical event | Verified app+shop HMAC or persisted pixel key |
| Identity | customers, sessions, session_aliases | Exact source receipt connection |
| Commerce | checkouts, orders | Verified webhook/canonical event lineage |
| Recovery | opportunities, recovery_sequences, recovery_interventions | Immutable source event → checkout/customer |
| Delivery | delivery_requests, delivery_attempts, tracking_tokens | Opportunity → recovery → intervention |
| Conversation | customer_conversations, conversation_messages | Exact delivery/recovery chain |
| Attribution | order_attributions, revenue_ledger | Same-connection order + opportunity + intervention |
| Cost | email_usage_measurements | Exact delivery attempt ancestry |
| Compliance | shopify_privacy_requests, consent/suppression records | Verified app+shop → exact connection |

Composite tenant+connection foreign keys are preferred where practical. Where a table already has an exact immutable parent relationship, derive and validate connection lineage through that parent rather than trusting duplicate metadata. Every writer must reject a supplied connection that disagrees with its parent lineage.

### Customer and session uniqueness

Do not immediately replace tenant-scoped unique indexes. First:
- Inventory every ON CONFLICT clause and all dependent readers.
- Quantify duplicate external customer IDs, normalized emails, checkout IDs/tokens, session references, event IDs and idempotency keys across stores within each tenant.
- Add nullable connection IDs and write both old and new identity fields.
- Dual-write, compare and quarantine ambiguous legacy rows.
- Only after collision handling and all readers are migrated, design connection-scoped uniqueness and update each conflict target atomically.

A shared human email across two stores is not evidence that the Shopify customer records are the same store identity. Customer identity is store-scoped by default; cross-store customer unification, if ever offered, must be a separate explicit feature.

## 7. Consent, unsubscribe and suppression policy

Shopify consent and unsubscribe are store-scoped by default. Add exact connection identity to consent evidence and unsubscribe token lineage. A suppression originating from Store A must not silently suppress Store B.

If a merchant later chooses a tenant-wide suppression policy, it must be an explicit policy setting and recorded as such. Preserve global legal/provider suppression where required, but distinguish it from Shopify store consent. Do not weaken opt-out behavior during migration: unresolved identity means suppress/hold sending safely, not send.

## 8. Privacy and shop-redact are release blockers

The live privacy handler uses a single global app secret. It is not ready for a second app identity until secret selection and HMAC verification are app-aware.

The current shop-redact database function deletes the entire tenant. That is not an acceptable store-redact behavior when one tenant can own multiple Shopify stores.

Required successor behavior:
- Resolve verified app key + shop domain to exact connection ID.
- Persist idempotent privacy receipt with app key and connection ID.
- If shop cannot be resolved unambiguously (including an uninstalled shop), retain REVIEW_REQUIRED; never guess.
- Customer export/redaction is restricted to the exact store connection and the relevant customer identity.
- Shop redaction removes that store's scoped data and credentials, but preserves other stores in the same tenant, tenant membership, and shared account/provider configuration according to retention rules.
- Retain a minimal compliance receipt and audit evidence without retaining unnecessary personal data.
- Make retries idempotent and test partial-failure recovery.

No public app release until this behavior is implemented and tested.

## 9. Billing decision remains deliberately deferred

Live control-plane revenue and billing summaries currently resolve a shop to a tenant and aggregate tenant-level measurements. Billing accounts are tenant-keyed. Do not silently label tenant-wide values as store-specific.

Before billing is made customer-facing, product must explicitly choose per-store, tenant-wide, or hybrid billing with transparent aggregation.

Recovered revenue is billable only when order, opportunity, recovery, intervention and source lineage all resolve to the same verified connection. Customer-only / ambiguous attribution remains non-billable.

## 10. Migration and rollout gates

1. Inventory gate: catalog, constraints, indexes, all writer overloads, triggers, function owners, grants, RLS policies and default privileges are reviewed.
2. Registry gate: exact current app provenance verified; registry created with secrets in Vault only.
3. OAuth gate: app-aware state, callback and finalizer implemented with same-shop conflict checks before Vault writes.
4. Ingress gate: app-aware Worker route and HMAC verifier; exact connection resolution; replay and header-spoof tests.
5. Source gate: webhook/canonical/pixel connection IDs dual-written and reconciled.
6. Identity gate: customers, sessions, checkout, order, recovery and delivery lineage dual-written and compared.
7. Privacy/consent gate: store-scoped export, redact, consent and unsubscribe pass tests.
8. Attribution gate: cross-store order attribution and stop-recovery tests pass.
9. Billing gate: explicit principal decision and store-safe aggregation implemented.
10. Public traffic gate: all gates signed off; rollback plan rehearsed; no unresolved ambiguous rows on the public path.

Rollback must disable the new app key/route and return new traffic to a safe holding state. It must not reassign tokens to the legacy app or drop nullable identity columns. Legacy functions remain available only to legacy routes.

## 11. Required two-store regression fixtures

Create an isolated database branch/test database with:
- Tenant T, Store A connected to legacy, Store B connected to public_v1.
- Same Shopify customer ID and same email in both stores, but distinct store-scoped customer rows.
- Same checkout token/session string in both stores, distinct store-scoped checkout rows.
- Same order ID / event ID / idempotency candidate values across stores to prove collision behavior is intentional and safely handled.
- Store A and Store B recovery opportunities and sequences for the same email.
- A Store B purchase must not suppress Store A recovery; a Store A unsubscribe must not suppress Store B by default.
- A Store B order must never attribute to Store A intervention or revenue ledger.
- Store A shop-redact must preserve Store B connection, customers, checkouts, orders and recovery history.
- A cross-app install attempt on the same shop must reject before Vault write.
- OAuth state replay, unknown/disabled app key, wrong-app HMAC, spoofed internal headers and inactive connection all reject.
- Delivery authorization rejects any mixed-connection ancestry.

No production merchant records should be copied into fixtures. Use synthetic IDs and payloads only.

## 12. Explicit non-actions

This blueprint does not execute DDL or DML, backfill app keys or connection IDs, change live RLS/grants/policies/function bodies, deploy Supabase Edge Functions or Cloudflare Workers, alter n8n workflows, change Shopify app ownership/credentials/scopes/releases, or merge the preparation PR.

**Current conclusion:** additive identity columns are necessary but insufficient. The hard part is trusted provenance and enforcement across the complete recovery, privacy, consent and attribution graph. Public traffic stays blocked until those contracts are implemented and tested end-to-end.
