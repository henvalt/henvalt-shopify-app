# ADR-001: Initial app-aware Shopify identity rollout

**Status:** Proposed; implementation contract only  
**Date:** 2026-11-16  
**Scope:** HENVALT Shopify app identity, OAuth, webhook ingress and connection ownership  
**Production effect:** None. This ADR is not executable SQL or deployment authorization.

## Decision

For the first public-app rollout, HENVALT will support **one HENVALT app identity per Shopify shop domain**, while allowing multiple different Shopify shops to belong to the same HENVALT tenant.

The canonical identity tuple is:

`app_key + shopify_connection_id + tenant_id + normalized_shop_domain`

This is deliberately narrower than supporting two HENVALT app registrations installed simultaneously on the same Shopify shop. The existing `shopify_connections.shop_domain` unique constraint already enforces one connection per shop. We retain it for the compatibility-first release.

### Why this decision

- It prevents the legacy merchant-owned app and future public app from overwriting each other's token references for the same shop.
- It avoids inventing a second connection model while existing writers/readers still assume shop-domain uniqueness.
- It supports independent commercial merchants: each merchant installs the public app on their own shop, while one HENVALT tenant may still own multiple different stores.
- It avoids a risky rewrite of OAuth, refresh, webhook, recovery and privacy paths in one release.
- It gives a deterministic conflict response instead of silently switching app ownership.

### Explicit behavior

| Situation | Required behavior |
|---|---|
| Legacy app installs a shop with no HENVALT connection | Create/claim a connection with `app_key=legacy` |
| Public app installs a different shop with no HENVALT connection | Create/claim a connection with `app_key=public_v1` |
| Legacy app tries a shop already connected to `public_v1` | Reject with `SHOP_ALREADY_CONNECTED_TO_DIFFERENT_HENVALT_APP`; do not update tokens |
| Public app tries a shop already connected to `legacy` | Same rejection; do not update tokens |
| Same app retries OAuth for the same shop | Idempotent finalize, bound to the exact app key and OAuth state |
| Connection is inactive/uninstalled | Do not reactivate via an ambiguous callback; require a new verified install flow and explicit state/ownership checks |
| App key unknown, disabled or missing | Fail closed; no legacy fallback |
| Shop lookup returns zero or multiple candidates | Reject/quarantine; never `LIMIT 1` to choose an identity |

Parallel app installations on the same Shopify shop are out of scope. Supporting them later requires changing the shop-domain uniqueness model and every shop-domain-only reader/writer; it is not a launch prerequisite.

## Registry and secret custody

Create a private `henvalt.shopify_app_registry` table with:
- `app_key` primary key (immutable stable internal key);
- `shopify_client_id` unique;
- `distribution_type` and lifecycle state;
- `api_secret_vault_name` (Vault secret name/reference, never secret value);
- `active`, created/updated timestamps and audit metadata.

Initial registry entries:
- `legacy`: existing merchant-owned app; preserve existing client ID and existing Vault secret `henvalt_shopify_app_secret`.
- `public_v1`: placeholder registry identity only when separately authorized and actual Shopify registration credentials exist. Do not create fake client IDs, secrets or active rows.

The registry must be inaccessible to anon/authenticated clients. Only server-side service-role functions may resolve the row and read the corresponding Vault secret. Callers may supply a validated app key, but may never supply an arbitrary Vault secret name.

## Schema contract

Additive first stage:
- `shopify_connections.app_key`: nullable during compatibility rollout, then backfilled only from verified install provenance; eventually NOT NULL after all writers and rows are reconciled.
- `shopify_oauth_states.app_key`: required for all newly created OAuth states; legacy states already in flight may be resolved only by the fixed legacy route during the compatibility window.
- Unique constraint on `shop_domain` remains unchanged in this rollout.
- Preserve all current Vault access/refresh token references and do not rename them.
- Add composite unique key `shopify_connections(tenant_id,id)` if absent, then composite FK prerequisites for child `(tenant_id,shopify_connection_id)` references.
- Do not add connection columns to all derived tables in one unreviewed mega-migration. Start with source-of-truth ingress records, then migrate writers/readers in staged batches.

Legacy connection backfill must use verified provenance: the current deployed app registration, OAuth install audit, token/secret reference history or another immutable source. Do not infer `legacy` solely from a row being active or being the only current connection.

## OAuth contract

1. Start route is app-specific and server-configured (e.g. legacy route vs future public route). The browser cannot choose arbitrary app key or client ID.
2. Generate a high-entropy state, store only its SHA-256 hash, and persist `app_key`, normalized shop domain, redirect/callback identity, initiating user, expiry and correlation ID.
3. Callback hashes the received state and resolves exactly one unexpired, unconsumed state before selecting app credentials.
4. Select Shopify client ID/secret from the registry row named by the stored state app key. Verify callback HMAC with that secret.
5. Exchange code with that same app's client ID/secret.
6. Finalize through a new app-aware RPC accepting state hash and app key; lock and consume state transactionally.
7. Before writing tokens, lock/check the existing shop connection. If its app key differs, reject without touching Vault or connection fields.
8. If the connection matches, update only that app's connection and Vault token refs. If no connection exists, create one and persist app key.
9. Idempotent callback replay must fail after state consumption and must never write tokens twice.

The current `control_plane_finalize_shopify_install_expiring_for_owner` / `control_plane_connect_shop(shop_domain)` path is legacy-only and must never be called for `public_v1`.

## Webhook contract

- Legacy route remains mapped to `app_key=legacy` and existing secret; no secret rotation.
- Future public route is separately mapped to `app_key=public_v1` and a distinct server-side secret binding.
- Worker route configuration, not unsigned body/header values, determines app key.
- Worker reads exact raw bytes and verifies HMAC before forwarding.
- Worker strips any incoming internal identity header and adds its own trusted app-key marker.
- n8n must reject missing/untrusted app identity and call app-aware Supabase verifier with raw-body base64 and HMAC.
- Supabase verifier independently loads the registry secret and verifies HMAC; it then resolves exactly one connection by `(app_key, normalized_shop_domain)` and confirms tenant and active/lifecycle state.
- Ingest payload receives trusted `app_key`, `shopify_connection_id`, `tenant_id` and normalized shop domain from the resolver. It must ignore/reject any caller-supplied values that conflict.
- No app key fallback to legacy; no shop-domain-only resolver in new path.

## Token refresh and lifecycle

Refresh claim/complete/fail operations must use `shopify_connection_id` and verify its app key. The worker loads the refresh token from that connection's Vault reference and Shopify client credentials from its app registry entry. A shop-domain argument alone is not sufficient.

Uninstall must resolve the same app+shop connection, revoke/disable only that connection, stop its recovery/delivery and preserve other stores in the tenant. Reinstall must not silently reuse stale token references without a fresh verified OAuth state.

## Acceptance tests

- Legacy callback still verifies with the existing legacy secret.
- Public callback verifies only with public_v1 secret.
- Legacy HMAC cannot authenticate a public route and vice versa.
- Unknown/disabled app key is rejected without fallback.
- OAuth state created for one app cannot be completed through another app route.
- Callback replay cannot rewrite tokens.
- Cross-app same-shop install returns conflict and leaves the existing connection and Vault refs unchanged.
- Two different shops under one tenant can bind to different app keys.
- Duplicate resolver rows fail closed rather than choosing first row.
- Token refresh for one connection cannot claim or update another connection.
- Uninstall for Store A does not deactivate Store B.
- Legacy webhook, OAuth, refresh and uninstall regression tests pass.

## Rollout / rollback

- Implement schema and RPC changes additively in a separate reviewed migration.
- Keep legacy Edge Function and Worker route intact until the app-aware route is fully verified.
- Deploy app-aware DB functions before app-aware callers, but do not switch legacy traffic until dual verification and regression tests pass.
- Canary with a test store and test-only delivery sink; recovery sends remain disabled.
- Rollback disables the new app route and new app installs; it does not delete registry history, Vault refs or legacy connections.
- No production change is authorized by this ADR.
