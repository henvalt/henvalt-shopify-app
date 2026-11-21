# App-aware identity migration design: additive Stage A–C

**Status:** review-only engineering design; not executable / not approved for production  
**Date:** 2026-11-16  
**Target:** preparation branch only  
**Production effect:** none. No SQL was applied, no secrets were read, and no application callers were changed.

## 1. Evidence snapshot (live catalog, read-only)

Project: ocyplckdojdubyrsxcxa, schema henvalt.

Verified live facts:
- shopify_connections has UUID primary key id, tenant FK, globally unique shop_domain, unique (tenant_id, shopify_shop_id), token Vault-reference columns, active flag and refresh lease fields.
- There is no (tenant_id,id) unique constraint today. Its UUID PK makes id unique globally, but a composite FK from tenant-bound children needs an explicit composite unique target (or equivalent validated FK design).
- shopify_oauth_states uses state_hash as PK and stores shop_domain, expiry, consumed timestamp, correlation ID and initiating user. It has no app key or callback/redirect identity.
- webhook_events and canonical_events have tenant identity and tenant-scoped idempotency, but no typed Shopify connection ID.
- pixel_keys.shopify_connection_id already references shopify_connections(id); preserve this existing exact lineage.
- Current source uniqueness is tenant-scoped: webhook event idempotency (tenant_id,idempotency_key) and (tenant_id,source,source_event_id); canonical event idempotency (tenant_id,idempotency_key).
- Current OAuth finalizer is control_plane_finalize_shopify_oauth_install_expiring_for_owner with state hash, shop domain, token inputs, expiry inputs, shop ID, scopes and user ID.
- Current HMAC verifier accepts HMAC and raw-body base64 only; current resolver accepts shop domain only. Both are legacy single-app contracts.
- Four connection rows were observed in the earlier identity audit. This is not proof of install provenance and must not be used as a blanket legacy backfill rule.

No secret values, access tokens, raw shop domains, tenant IDs or customer records are reproduced here.

## 2. Migration objective and hard invariants

Introduce app identity as a first-class, server-owned dimension while preserving the existing legacy app and current shop-domain uniqueness.

Trusted identity tuple: app_key + shopify_connection_id + tenant_id + normalized_shop_domain.

Initial public rollout:
- one HENVALT app identity per Shopify shop;
- multiple different Shopify shops may belong to one tenant;
- cross-app install against an already-connected shop is a conflict before Vault writes;
- unknown, inactive, missing or ambiguous app identity fails closed;
- no fallback to the legacy secret or resolver;
- no existing writer switches until v2 writers and regression tests are ready.

## 3. Proposed Stage A — private app registry

Proposed table henvalt.shopify_app_registry:

| Field | Type | Requirement |
|---|---|---|
| app_key | text | PK; immutable; constrained to registered stable keys |
| shopify_client_id | text | NOT NULL, UNIQUE |
| distribution_type | text | CHECK limited to supported distribution types |
| api_secret_vault_name | text | NOT NULL; secret reference only |
| active | boolean | NOT NULL DEFAULT false |
| created_at, updated_at | timestamptz | audit timestamps |

Security:
- RLS enabled and forced where compatible with service-role function access.
- No anon/authenticated table grants and no client-facing policies.
- Service-role functions may resolve registry records; callers never provide a Vault secret name.
- Never store plaintext app secrets or Admin API tokens in this table.
- Do not insert a public_v1 row until actual Shopify registration and its secret reference exist and the user separately authorizes that registration.
- A legacy row must be seeded only after a controlled comparison of the deployed client ID and existing Vault secret name/reference. This document does not authorize reading or exposing the secret value.

## 4. Proposed Stage B — nullable identity on existing anchors

Add nullable app_key to:
- henvalt.shopify_connections
- henvalt.shopify_oauth_states

Keep:
- shopify_connections.shop_domain global unique constraint;
- current UUID PK and token reference columns;
- OAuth state hash PK, expiry and one-time consumption behavior.

Add composite unique key on shopify_connections(tenant_id,id) only after checking duplicate/null impossibility (tenant_id is currently NOT NULL and id is PK). This key is a prerequisite for tenant-consistent composite FKs from source records.

Backfill policy:
- First produce a per-row provenance report in a controlled, non-secret form.
- Evidence may include immutable OAuth state/correlation/audit linkage, original install source, and Vault reference lineage.
- Do not backfill from active=true, current row count, only-known-app assumptions, shop domain alone, or current Worker secret configuration.
- Rows without unique immutable provenance remain NULL and are quarantined from new app-aware traffic until manually resolved.
- Do not set NOT NULL until all rows and all writers are reconciled.

OAuth state additions:
- new state creation must persist app key and server-selected callback route identity;
- state app key is immutable after creation;
- callback must match app key, normalized shop and callback route;
- legacy unconsumed states may only complete through the fixed legacy route during a bounded compatibility window;
- state remains one-time and is consumed transactionally.

## 5. Proposed Stage C — source-of-truth ingress lineage

Add nullable shopify_connection_id to:
- henvalt.webhook_events
- henvalt.canonical_events

Add composite FK (tenant_id,shopify_connection_id) to (tenant_id,id) on shopify_connections, initially NOT VALID if supported and then validated after a null/invalid-reference scan. Null remains permitted during dual-write migration.

Writer requirements:
- raw webhook is HMAC-verified using the trusted route's app key before identity resolution;
- exact resolver returns one active connection matching (app_key, normalized_shop_domain);
- webhook receipt stores tenant + connection from resolver, not request body;
- canonical event inherits connection from its referenced webhook receipt; for pixel events, inherit exact connection from pixel_keys.shopify_connection_id;
- if both event and receipt carry connection IDs, they must match;
- reject/quarantine missing, conflicting, inactive or ambiguous lineage;
- do not infer connection from tenant-only or event metadata.

Idempotency:
- retain existing tenant-scoped uniqueness during compatibility rollout;
- before making idempotency store-scoped, quantify duplicate keys and design conflict-safe dual-key semantics;
- app key should not be silently appended to idempotency keys in a way that permits the same Shopify event to be processed twice by two app identities;
- existing unique shop-domain policy already prevents same shop being simultaneously assigned to two app keys.

## 6. Explicitly deferred — derived graph

Do not add all downstream columns in the first migration. After source ingress is proven, migrate in dependency order:
1. customers, sessions, session aliases, checkouts, cart snapshots;
2. opportunities and orders;
3. recovery sequences and interventions;
4. delivery requests and attempts;
5. conversations, messages, provider replies, unsubscribe tokens and suppressions;
6. order attribution, revenue ledger and email usage;
7. privacy request/receipt lineage;
8. billing only after billing principal decision (tenant/store/hybrid).

Every child relation must validate both tenant and connection. Parent composite unique keys must be established before composite FKs. Existing tenant FKs and RLS must remain in place.

## 7. Migration batches and release gates

### Batch 0 — freeze evidence
- snapshot table columns, constraints, indexes, triggers, RLS policies, grants, function signatures/bodies, Edge Function versions, Worker routes and n8n workflow versions;
- generate row-level provenance classifications without exposing secrets;
- quantify source rows missing or ambiguously resolving to a connection.

### Batch 1 — additive registry and anchor columns
- create private registry;
- add nullable app_key columns;
- add composite unique key on connection tenant/id;
- no backfill by default;
- no caller change.

### Batch 2 — app-aware OAuth and resolver RPCs
- create v2 functions alongside legacy;
- registry lookup never accepts arbitrary secret reference;
- state app key + callback route are locked and consumed atomically;
- cross-app shop conflict occurs before any Vault write;
- token write is tied to exact connection ID.

### Batch 3 — source event lineage
- add nullable connection columns and composite FK;
- deploy dual-write only after RPC tests in an isolated database;
- reconcile pixel event path using existing pixel-key connection FK;
- preserve old RPCs and legacy ingress route.

### Batch 4 — downstream lineage
- migrate candidate discovery, eligibility, consent, suppression, recovery, delivery, replies, conversion stop, attribution, privacy and dashboard in dependency order;
- do not enable recovery sends until authorization validates exact same-connection lineage end-to-end.

### Release gates (all required)
- zero cross-tenant or cross-connection FK violations;
- no ambiguous legacy backfill;
- legacy install/webhook/refresh/uninstall tests pass;
- public-vs-legacy HMAC isolation passes;
- callback replay and same-shop cross-app conflict pass without Vault writes;
- two distinct stores under one tenant remain isolated through checkout, customer, order, recovery, delivery, reply, opt-out, attribution and dashboard;
- store-redaction never deletes another store or whole tenant;
- security grants/RLS and rollback rehearsed;
- separate explicit production release authorization.

## 8. Rollback and non-goals

Rollback before traffic switch: disable new routes and v2 callers; retain nullable columns, registry history and legacy path. Do not drop columns or delete Vault refs during rollback.

This design does not:
- create a Shopify Partner app or incur fees;
- modify the existing merchant-owned app or its credentials;
- apply migrations or backfill production rows;
- edit Cloudflare, Supabase functions, n8n or Shopify configuration;
- decide tenant/store billing;
- authorize public app launch or production recovery sends.

## 9. Required next evidence before executable migration SQL

1. Complete RLS policy/grant/default-privilege audit for all touched tables.
2. Inspect every writer RPC and Edge Function caller for webhook receipt, canonical event, customer, checkout and order projection.
3. Inspect triggers and generated columns on touched tables.
4. Produce provenance classification counts by table without exposing identifiers.
5. Confirm whether any existing unique constraint or index is relied upon by conflict targets in writer functions.
6. Build isolated two-store fixtures and run SQL-level tests before preparing executable migration files.

**Safety note:** this is an engineering design artifact only. It is not a migration and must not be passed to Supabase apply_migration.


## 10. Additional live RLS and grant evidence (read-only)

A second catalog pass verified:
- RLS is enabled on shopify_connections, shopify_oauth_states, webhook_events, canonical_events and pixel_keys.
- RLS is not forced on those five tables.
- A tenant_isolation policy exists on shopify_connections, webhook_events and canonical_events, using henvalt.is_tenant_member(tenant_id) for both USING and WITH CHECK.
- No policy rows were returned for shopify_oauth_states or pixel_keys. This is consistent with their intended server-only access, but the full schema/role and function execution paths must be reviewed before changing grants.
- The inspected grants showed no anon or authenticated table grants on these five tables. service_role has read access to connections and canonical events; OAuth state has service_role CRUD/administrative grants; pixel_keys has service_role CRUD grants. webhook_events had no direct service_role table grant in this inspection, so existing security-definer writer behavior must be preserved and its effective function ACLs audited.
- Do not use FORCE ROW LEVEL SECURITY as a casual hardening change: security-definer owners and service-role call paths must be tested first. The registry should be protected by both explicit grants and RLS, with no browser-facing policy.

These findings are a scoped catalog snapshot, not a complete security audit. Default privileges, all overloads, non-security-definer functions, schema USAGE, and function-owner bypass behavior remain separate checks.
