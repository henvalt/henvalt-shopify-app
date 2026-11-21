# Shopify Webhook App/Store Identity Binding — Security Gate

**Status:** design and static validation only. This document authorizes no production changes.
**Inspection date:** 2026-11-16
**Live systems inspected:** Cloudflare Worker source on preparation branch; active n8n `HENVALT_INGEST`; Supabase `henvalt` function definitions and table catalog.

## 1. Confirmed Shopify protocol boundary

Shopify's official webhook documentation states that:
- `X-Shopify-Hmac-Sha256` is an HMAC of the exact raw request body, generated with the app's shared secret.
- `X-Shopify-Shop-Domain`, `X-Shopify-Topic`, `X-Shopify-Webhook-Id`, API version and timing/delivery IDs are request headers.
- The HMAC verification instructions sign the raw body; they do not include the shop-domain header in the HMAC input.

Sources:
- Shopify webhook headers: https://shopify.dev/docs/api/webhooks/latest
- Shopify delivery structure: https://shopify.dev/docs/apps/build/webhooks/delivery-structure
- Shopify verification: https://shopify.dev/docs/apps/build/webhooks/verify-deliveries

Therefore a valid HMAC proves the body was signed with the app secret. By itself it does **not** cryptographically bind the separate `X-Shopify-Shop-Domain` header to that body.

## 2. Confirmed HENVALT live design

### Cloudflare Worker (branch source; same architecture as inspected)
- One `SHOPIFY_API_SECRET` binding verifies every incoming Shopify webhook.
- It accepts `X-Shopify-Shop-Domain` as a routing header after format validation.
- It forwards the original raw body and allowlisted Shopify headers to n8n.
- It has no per-app key registry or per-connection ingress identity in the current contract.

### Shopify OAuth callback (branch source; not deployed by this preparation)
- The OAuth Edge Function uses one global `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET` for install, callback verification and token exchange.
- After OAuth, it registers webhook subscriptions through each shop's Admin GraphQL API, but every shop receives the exact same static URI: `https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks`.
- It does not create or persist a per-connection route token.
- This confirms that a per-shop opaque callback route is a feasible design change in the existing registration point, but it must be additive and tested before subscription cutover.

### Active n8n `HENVALT_INGEST`
- The workflow independently calls `henvalt.verify_shopify_webhook_hmac`, which reads one Vault secret named `henvalt_shopify_app_secret`.
- If that verifier returns false, the false output of `HMAC Verified?` is unconnected.
- On a valid result, the workflow calls `henvalt.resolve_shopify_tenant(p_shop_domain)`.
- The resolver returns only a tenant UUID, not a connection ID or app identity.
- The resolver compares normalized domain but uses `LIMIT 1`.
- Downstream webhook ingestion and canonical event writing are tenant-scoped, not connection-scoped.
- The Webhook node uses `responseMode: onReceived`; the HTTP request is acknowledged before HMAC/tenant processing completes. The upstream 200 is not proof of successful verification or ingestion.

### Supabase catalog
- `shopify_connections` has `id`, `tenant_id`, `shop_domain`, `shopify_shop_id`, token references, scopes and active state.
- It has no app/client identity column.
- `webhook_events` has tenant ID, source IDs, topic, idempotency, payload and JSON metadata, but no connection/app foreign key.
- `shopify_connections.shop_domain` has a case-sensitive unique index on the raw column; there is no unique index on normalized lowercase domain.
- The current Vault verifier chooses one global secret. It cannot select the correct secret when the future public Partner-owned app has a different client secret.

## 3. Threat and failure modes

1. **Header/body routing substitution:** A captured valid signed body can be replayed with a changed `X-Shopify-Shop-Domain` header. The HMAC still verifies because the header is outside the signed bytes. If the target shop is another active connection, current tenant resolution can route the event using the altered header.
2. **Same-tenant store collision:** The two stores can share a tenant. Current webhook idempotency and canonical event keys are tenant-scoped; identical event/event IDs can collapse or suppress one another.
3. **App identity ambiguity:** One global secret and no app identity on connections cannot safely support the existing merchant-owned app and a future Partner-owned public app with different secrets.
4. **Shared callback route:** Every connected shop currently registers the same Worker URL. There is no per-install route token to bind a delivery to its exact connection before using the unsigned shop-domain header.
5. **False-verification acknowledgement:** n8n acknowledges at receipt time. If Worker and Vault secrets ever diverge, Worker can return 200 after forwarding even though n8n's second verification fails. Shopify may stop retrying a delivery that HENVALT did not process.
6. **Case-normalization ambiguity:** The resolver lowercases for lookup while the unique index is case-sensitive. If case-variant duplicates exist, `LIMIT 1` can choose an arbitrary connection's tenant.

## 4. Required V2 identity contract

### Per-app secret registry
Create a server-only app registry keyed by immutable internal app identity (not by merchant input), containing:
- app_key / app identity;
- Shopify client ID (non-secret identifier);
- Vault secret reference for that app's client secret;
- lifecycle state (active, rotating, retired);
- allowed distribution class/environment.

Do not store decrypted secret values in ordinary tables or return them from APIs. Do not choose an app secret based on a caller-supplied shop header alone.

### Per-connection webhook route binding
For each installed shop, create an unguessable per-connection webhook route token and persist only its hash, mapped to the exact connection and app identity. Register that connection-specific HTTPS callback URI with Shopify using the installed shop's authenticated Admin API. On receipt:
1. Resolve the route token to exactly one active connection and app identity.
2. Select that app's Vault secret and verify raw-body HMAC.
3. Validate `X-Shopify-Shop-Domain` equals the connection's canonical shop domain.
4. Where Shopify resource payloads contain a stable shop ID, validate it equals the connection's stored `shopify_shop_id`; never rely on it if absent.
5. Validate topic, delivery ID, route state, active connection and app state.
6. Persist the verified app ID + exact connection ID with the receipt before any tenant-scoped processing.
7. Derive tenant ID from that connection row. Ignore tenant IDs, connection IDs, shop domains and app IDs supplied in body fields or arbitrary headers for authorization.
8. Deduplicate by app + connection + Shopify webhook delivery ID; retain Shopify event ID separately as cross-topic correlation, not as a replacement for per-delivery ID.

If a topic's body lacks a stable shop identifier, the per-connection callback route is the binding mechanism; header equality is an additional consistency check, not the root of trust.

### Route-token lifecycle
- Generate high-entropy random token per connection; store a cryptographic hash only.
- Never log or expose the token after initial Shopify subscription registration.
- Rotate by registering new subscription first, then switch active route token, then retire old subscription/token after delivery overlap is handled.
- Unknown, expired, revoked or ambiguous token fails closed.
- A route token is a bearer routing credential, not a replacement for HMAC. Both checks are mandatory.

### Delivery acknowledgement
Do not acknowledge successful receipt before durable verified identity and idempotent webhook receipt persistence. If the n8n webhook must remain `onReceived`, move the synchronous verification + route-token binding + durable receipt to the Cloudflare Worker and return success only after that operation confirms persistence. Otherwise use a synchronous webhook response path within Shopify's response deadline. A later background processing failure must be durably retryable/reconcilable; a 200 only means the verified receipt is safely persisted, not that recovery has completed.

## 5. Additive schema / function design (not applied)

- `shopify_app_registry`: immutable app identity, client ID, Vault secret reference, status.
- `shopify_connections.app_key`: FK to app registry.
- `shopify_connections`: normalized canonical shop domain constraint (after duplicate preflight), retain existing unique domain identity.
- `shopify_webhook_route_tokens`: token hash, connection ID, app key, created/expiry/revocation state, unique token hash.
- Add a separate `shopify_webhook_deliveries` durable inbox keyed by `(connection_id, shopify_delivery_id)`. Its composite foreign key binds connection + tenant + app + canonical shop domain, preventing a Store A connection from storing a Store B header.
- Keep the existing tenant-scoped `webhook_events` table and its uniqueness constraints untouched during this foundation stage. A later, separately tested adapter must map verified inbox rows into recovery processing with explicit connection lineage; do not assume the current legacy tenant-level writer is safe for cross-store reuse.
- New resolver/ingest RPC accepts only the verified route-token hash + app context and returns/uses exact connection ID; tenant is derived from the connection inside SQL.
- Add a composite FK or equivalent integrity guard so webhook tenant and connection tenant cannot disagree.
- New unique idempotency constraint/index must be designed with every writer and existing duplicates/ON CONFLICT clauses inventoried first. Do not drop current unique constraints in this design phase.

## 6. Required security tests

1. A signed body + route token for Store A + header A is accepted for A.
2. Same signed body + route token A + changed header B is rejected before tenant resolution/write.
3. Same signed body + route token B is rejected when it was registered for app/store A.
4. A route token from one app cannot select another app's secret.
5. Unknown, expired, revoked or ambiguous route token is rejected.
6. Valid HMAC but inactive connection or retired app is rejected.
7. Body shop ID, when present, must match connection shop ID.
8. Caller-supplied tenant/connection/app IDs never override route binding.
9. Same Shopify delivery ID from Store A and Store B is isolated by connection identity.
10. Repeated delivery to the same connection is idempotent.
11. Worker/Vault secret mismatch cannot result in a false 200 acknowledgement.
12. HMAC false branch is explicitly handled; no downstream tenant resolution occurs.
13. Case-variant duplicate shop domains are rejected as ambiguous until canonicalized.
14. Existing app and future Partner-owned app with different secrets validate only under their own app registry entries.
15. Uninstall revokes that connection's route tokens and stops further event processing without deactivating another store in the same tenant.

## 7. Cutover order

A. Build read-only app/connection/route-token schema preflight and duplicate checks.
B. Confirm how current Shopify subscriptions are registered (static app TOML versus per-shop Admin GraphQL) and enumerate their callback URLs.
C. Implement V2 registry, route token, verifier and durable receipt writer in isolated tests.
D. Test cross-store header substitution and replay with synthetic Store A/Store B fixtures.
E. Shadow-compare legacy routing with V2; legacy records remain unresolved where provenance cannot be proven.
F. Only after separate explicit approval, deploy the V2 ingress path and register new per-store webhook subscriptions.
G. Keep old app secret and existing installed app intact; future Partner app uses its own app registry entry and secret.

## 8. Non-actions

This is a security design only. No production schema, row, function, Vault entry, Cloudflare binding, n8n workflow, Shopify webhook subscription, app identity, secret or deployment was changed. No app secret was read or printed. Implementation/cutover requires separate explicit authorization.
