# App-aware Shopify identity: implementation contract v1

**Status:** engineering handoff / design contract only  
**Date:** 2026-11-16  
**Based on:** deployed PostgreSQL function signatures and schema inventory, OAuth Edge Function v27, Cloudflare Worker source, and active n8n workflows  
**Production effect:** none. No migration, code deployment, workflow edit or secret operation is included.

## 1. Non-negotiable invariants

1. Existing app registration is `legacy`; its Shopify client ID, app secret, Vault secret name, OAuth installations and tokens remain untouched.
2. First public rollout supports one HENVALT app identity per Shopify shop. Keep the existing unique `shopify_connections.shop_domain` constraint. A second app identity attempting the same shop must get a conflict, never an overwrite.
3. Different shops may belong to the same tenant and may use different app keys.
4. Trusted identity is `app_key + shopify_connection_id + tenant_id + normalized_shop_domain`.
5. App key comes from a trusted route and one-time OAuth state, never from a body/query/header chosen by the merchant/browser.
6. Connection ID and tenant ID are resolved server-side after HMAC/state verification. Do not accept caller-supplied tenant or connection identity.
7. Missing, inactive, conflicting or ambiguous identity fails closed. No fallback to legacy.
8. Plaintext app secrets and Admin API tokens remain in managed secret storage. Ordinary DB columns store references only.
9. No existing writer or reader is switched until additive DB functions and regression coverage are ready.
10. Legacy traffic remains operational during every stage.

## 2. Database objects and staged changes

### Stage A — app registry

New private table proposal: `henvalt.shopify_app_registry`.

| Column | Type | Constraint / purpose |
|---|---|---|
| app_key | text | PK, immutable |
| shopify_client_id | text | NOT NULL, UNIQUE |
| distribution_type | text | CHECK: merchant_owned/public |
| api_secret_vault_name | text | NOT NULL; Vault secret name, not secret value |
| active | boolean | NOT NULL DEFAULT false |
| created_at / updated_at | timestamptz | audit timestamps |

Access: no anon/authenticated table grants; service-role only. No client-facing RLS policy. Do not seed `public_v1` as active or invent credentials. Seed the legacy row only after matching the existing deployed client ID and Vault secret reference through an authorized, read-only evidence check.

### Stage B — bind app identity to existing rows

- Add nullable `app_key` to `shopify_connections`.
- Add nullable `app_key` to `shopify_oauth_states`.
- Preserve the unique `shop_domain` constraint and all existing token reference fields.
- Add/verify unique `(tenant_id,id)` on `shopify_connections` as the target for composite child FKs.
- Backfill only rows with verified legacy OAuth provenance. The current single-app deployment is strong context, but do not update rows without checking install/audit provenance and Vault references.
- Do not make `app_key` NOT NULL until every row is classified and every writer uses it.

### Stage C — ingress source lineage

Add nullable `shopify_connection_id` to `webhook_events` and `canonical_events`, with composite FK `(tenant_id,shopify_connection_id) → shopify_connections(tenant_id,id)`. Persist `app_key` either directly or through the immutable connection relation; if copied for efficient routing, enforce equality with the connection's app key using a trusted DB write contract/constraint.

Pixel path already has `pixel_keys.shopify_connection_id`; preserve and propagate that exact ID into event records.

### Stage D — derived lineage

Migrate in dependency order, not one blind ALTER:
1. customers, checkouts, sessions, session_aliases and cart snapshots;
2. opportunities and orders/order adjustments;
3. recovery sequences, interventions, delivery requests and delivery attempts;
4. conversations, messages, inbound provider events, tracking/unsubscribe tokens;
5. order attributions and revenue ledger;
6. privacy request/receipt rows.

Each connection FK must be tenant-consistent. Do not create a composite FK until the corresponding parent unique key exists and data has passed preflight. Preserve old tenant FKs and old uniqueness during dual-write period.

## 3. New server-side RPC contracts

Names below are proposed v1 interfaces; they are not deployed and must be reconciled with the final schema before implementation.

### Registry and OAuth

- `get_shopify_app_config(p_app_key text)` → client ID, secret reference and lifecycle state for trusted server use only.
- `create_shopify_oauth_state(p_app_key text, p_shop_domain text, p_state_hash text, p_user_id uuid, p_redirect_key text, p_expires_at timestamptz)` → correlation/state record.
- `finalize_shopify_oauth_install_v2(p_state_hash text, p_app_key text, p_shop_domain text, p_access_token text, p_refresh_token text, p_access_expires_in integer, p_refresh_expires_in integer, p_shopify_shop_id text, p_scopes text[], p_user_id uuid)` → installed flag, tenant ID, exact connection ID.
  - Lock and consume the OAuth state.
  - Assert the app key matches the stored state.
  - Assert callback shop matches stored normalized shop.
  - Lock existing shop connection.
  - If existing app key differs, return conflict before any Vault write.
  - Store tokens in Vault and refs on that exact connection only.
  - If no connection, create it with app key and tenant binding.
  - Consume state atomically; replay fails.
- Legacy OAuth finalizers remain legacy-only. They must not be called by public app callbacks.

### Webhook verification and resolution

- `verify_shopify_webhook_hmac_v2(p_app_key text, p_hmac text, p_raw_body_base64 text)` → boolean.
  - Resolve secret name only from active registry row.
  - Reject unknown/inactive key; no global-secret fallback.
  - Verify HMAC over exact decoded raw bytes.
- `resolve_shopify_connection_v2(p_app_key text, p_shop_domain text)` → `{app_key,shopify_connection_id,tenant_id,shop_domain,active}`.
  - Exact normalized equality on app key + shop domain.
  - Require exactly one row and active tenant/connection for ordinary event topics.
  - Compliance topics may resolve a retained inactive connection under a separate, explicit policy.
  - Zero or multiple rows → structured error; never `LIMIT 1`.

### Refresh and lifecycle

- `claim_shopify_token_refresh_v2(p_shopify_connection_id uuid, p_force boolean)`
- `complete_shopify_token_refresh_v2(p_shopify_connection_id uuid, p_refresh_lease_id uuid, ...)`
- `fail_shopify_token_refresh_v2(p_shopify_connection_id uuid, p_refresh_lease_id uuid, ...)`
- `disconnect_shopify_connection_v2(p_app_key text,p_shop_domain text,p_webhook_event_id uuid,p_correlation_id uuid)`

Refresh must resolve app credentials and token refs from the exact connection. A shop-domain-only refresh contract is legacy-only. Uninstall disables only the exact app+connection; no tenant-wide cascade.

### Event ingest

- `ingest_raw_webhook_v2` successor must accept server-verified app key and connection ID, assert tenant matches connection, and persist both on the webhook receipt.
- `upsert_canonical_event_v2` and subsequent customer/checkout/opportunity/order writers must derive or assert connection identity from the trusted event row.
- Any client-supplied identity fields must be rejected if conflicting and must never override server-derived values.

## 4. Cloudflare and n8n envelope

### Worker routes

- Existing `POST /shopify/webhooks` stays legacy and continues using its current secret binding.
- Future public app uses a distinct app-specific route, e.g. `POST /shopify/webhooks/public_v1`, mapped in Worker code/config to `app_key=public_v1` and a distinct secret binding.
- Route mapping is static/trusted. Do not select key from `X-Shopify-Shop-Domain`, body JSON, or arbitrary incoming header.
- Worker verifies raw body first, removes any inbound internal identity header, then sets its own internal app-key marker on the server-to-server forward.
- n8n authenticates the Worker-to-n8n call separately from Shopify HMAC.

### HENVALT_INGEST

Required order:
1. authenticate internal Worker caller;
2. validate trusted app key from authenticated Worker envelope;
3. re-verify Shopify HMAC through `verify_shopify_webhook_hmac_v2`;
4. resolve exact connection through `resolve_shopify_connection_v2`;
5. construct a server-owned identity object;
6. pass that object to ingest RPC; reject payload/query identity conflicts.

Do not trust the current `resolve_shopify_tenant(shop_domain)` as the final app-aware resolver. Keep it for the legacy compatibility path only.

### HENVALT_RECOVERY / HENVALT_DELIVERY

- Recovery candidate and context RPCs return exact connection ID and app key.
- Recovery delivery payload includes these identifiers only as context; delivery authorization must independently derive and compare them from DB lineage.
- Delivery authorization validates delivery request → intervention → sequence → opportunity → customer/checkout/source event → active connection → app key, all same tenant/connection.
- MailerSend credential/sender configuration can remain tenant-shared only under explicit policy; store-specific sender profile selection must use connection ID.
- Any mismatch denies send and creates structured audit reason.

## 5. Current deployed function compatibility map

| Current deployed contract | Limitation | Migration treatment |
|---|---|---|
| `verify_shopify_webhook_hmac(text,text)` | One Vault secret name; no app key | Keep for legacy route; add v2 |
| `resolve_shopify_tenant(text)` | Returns tenant only; shop-domain lookup | Keep legacy-only; add v2 exact connection resolver |
| `control_plane_connect_shop(text)` | Shop-domain only; can return existing connection | Legacy-only; do not call from public OAuth |
| `control_plane_finalize_shopify_oauth_install_expiring_for_owner(...)` | State and connection have no app key | Keep legacy-only; add app-aware finalizer |
| `claim_shopify_token_refresh(text,boolean)` | Shop-domain keyed | Keep legacy-only; add connection-keyed refresh |
| `complete_shopify_token_refresh(text,...)` | Shop-domain keyed | Keep legacy-only; add connection-keyed completion |
| `fail_shopify_token_refresh(text,...)` | Shop-domain keyed | Keep legacy-only; add connection-keyed failure |
| `get_recovery_worker_context(uuid)` | No validated connection returned | Add/upgrade after lineage fields |
| `authorize_delivery_request(...)` | No complete same-connection comparison | Add strict connection-aware authorization before sends |

## 6. Migration sequence and deploy ordering

1. Freeze and snapshot schema/RPC signatures, app registrations, Worker routes, Edge Function versions and n8n workflow versions.
2. Create private registry + nullable app_key columns + unique/compound key prerequisites; no caller changes.
3. Verify and classify legacy connection rows; do not guess.
4. Add v2 RPCs alongside legacy RPCs. Add tests before any caller switch.
5. Add new Edge Function code paths with app-specific routes/state; legacy route remains unchanged.
6. Add Worker route mapping and secret binding only after explicit secret availability and user approval; no public route until actual registration exists.
7. Add n8n v2 ingest path and dual verification in test environment.
8. Add connection columns and dual-write to source events, then derived records.
9. Migrate readers and enforce recovery/delivery/attribution/privacy same-connection invariants.
10. Run two-store/two-app tests in isolated test environment; run legacy regression.
11. Canary with recovery disabled and test-only delivery sink.
12. Separate explicit production release approval.

## 7. Rollback boundaries

- If v2 path fails before traffic switch, keep legacy path untouched and disable v2 route.
- If dual-write fails, preserve nullable columns and stop new app installs; do not remove legacy fields.
- If readers fail, route legacy traffic to existing readers only when doing so cannot cross stores; otherwise fail closed and pause sends.
- Never roll back by restoring a global secret over an app-specific secret.
- Never delete app registry history, Vault token refs or connection records during rollback.
- Do not drop old constraints or columns in the first release.

## 8. Open decisions

- Billing principal: per store, per tenant or hybrid (separate ADR required before billing schema migration).
- Whether tenant-wide suppression is an optional merchant policy; default store-scoped.
- Retention policy for uninstalled connections and compliance receipts.
- Exact app-specific Worker route naming and binding deployment mechanics.
- Whether `app_key` is duplicated on every child record or derived through a strict immutable connection FK. Prefer FK as authority; duplicate only where query performance requires it and enforce equality.
