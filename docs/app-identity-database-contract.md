# HENVALT app-identity and store-boundary database contract

Status: design only, not an executable migration. Prepared from read-only inspection of the live Supabase schema, RPC definitions, and deployed Edge Functions on 2026-11-16. Do not apply this document to production.

## 1. Design goals

- Keep the current merchant-owned Shopify app operational as the legacy app.
- Prepare a separate Partner-owned public app without replacing legacy credentials or app identity.
- Preserve tenant isolation and current Supabase Vault token storage.
- Support multiple Shopify stores under one tenant.
- Prevent a second app identity from overwriting another app's OAuth state, token pair, connection, webhook verification, or uninstall lifecycle.
- Make the distinction between store-scoped data and tenant-shared configuration explicit.
- Fail closed when app identity, store selection, tenant membership, or data ownership is ambiguous.

## 2. Existing invariants that must not be broken

1. `shopify_connections.shop_domain` is currently unique. Keep this uniqueness during the first public-app rollout if the product policy remains one active HENVALT app identity per Shopify shop. This avoids same-shop legacy/public collision while allowing different shops under one tenant to use different app identities.
2. `shopify_connections` already allows multiple rows per tenant; live read-only inspection found a tenant with two active connections. Never introduce a one-connection-per-tenant constraint.
3. `shopify_connections` has tenant-isolation RLS. Preserve its policy.
4. `shopify_oauth_states` has RLS enabled and no ordinary row policy. Keep OAuth-state writes and reads behind trusted service-role/RPC code; do not add authenticated-user table access.
5. Shopify access/refresh tokens are stored as Vault secret references. Continue storing references, never plaintext token values, in ordinary tables.
6. Pixel keys reference an exact `shopify_connection_id`; preserve this exact connection binding.
7. MailerSend provider credentials are tenant/provider resources and must not be mixed with Shopify app secrets.
8. Existing legacy secret references and OAuth installations must remain valid through an additive, reversible rollout.

## 3. Proposed app registry

Create a private registry table in the `henvalt` schema, not exposed to ordinary client roles.

Conceptual fields (names are proposals, not migration SQL):

| Field | Purpose |
|---|---|
| `app_key` | Stable internal identifier, e.g. `legacy`, `public_v1`; never a Shopify client ID |
| `shopify_client_id` | Shopify app client ID; unique |
| `secret_vault_name` | Name/reference of the app's Shopify secret in Vault |
| `active` | Allows safe activation/deactivation without deleting identity history |
| `distribution_type` | Internal/merchant-owned/public; operational metadata only |
| `created_at`, `updated_at` | Auditability |

Security requirements:
- The registry must not contain plaintext Shopify app secrets.
- Only trusted server-side functions/service role may read app configuration and resolve Vault secrets.
- Never expose app registry rows or Vault secret references to browser clients.
- Do not let callers choose an arbitrary Vault secret name; app key must resolve through a fixed, trusted registry row.

## 4. OAuth state and connection binding

Add an app identity reference to OAuth state and each Shopify connection.

- `shopify_oauth_states.app_key`: required for new flows; written at install initiation and read back during callback.
- `shopify_connections.app_key`: required after legacy backfill; identifies which HENVALT app owns the connection.
- OAuth state consumption, tenant ownership validation, connection creation/update, and Vault token-reference persistence must happen atomically or through an idempotent transaction boundary.
- Callback must use the app key stored in the one-time state to choose client ID and secret. Never choose credentials from callback parameters, shop headers, or an unsigned request field.
- Refresh claim must return the connection's immutable app key along with the correct refresh-token reference. Complete/fail operations must be bound to the same connection/app key and refresh lease generation.
- Keep current `shop_domain` unique constraint for first rollout. Reject same-shop installation from a different app key with a clear conflict response; never overwrite the existing connection.
- Preserve existing legacy token Vault references during backfill. Do not rename or rotate them merely to fit the new naming convention.

## 5. Webhook identity contract

- Each app has an explicit ingress route mapped to a fixed app key by server configuration.
- Worker chooses the secret from the trusted app registry, verifies HMAC over the exact raw request bytes, then forwards the verified app key internally.
- Strip any caller-supplied copy of the internal app-key header before setting the trusted value.
- n8n must pass app key, original HMAC, and raw-body base64 to an app-aware Supabase verifier.
- Supabase independently checks that the app is active, verifies HMAC with that app's Vault secret, and resolves the connection by app key plus shop domain.
- Unknown/inactive app key, wrong app/shop pairing, malformed HMAC, and mismatched connection must fail closed. No fallback to the legacy secret.
- OAuth webhook registration, privacy subscriptions, and uninstall events must use the same app-specific route.

## 6. Store-scoped versus tenant-scoped data

The database and deployed functions currently mix these scopes. The following is the proposed default contract; each exception must be deliberate and documented.

| Resource | Proposed scope | Reason |
|---|---|---|
| Shopify app registry / app secret | App | One credential set per Shopify app |
| OAuth state | App + shop + one-time state | Callback must recover exact initiating app |
| Shopify connection / Admin API tokens | Store connection | Credentials belong to one shop installation |
| Shopify webhook identity | App + store connection | HMAC and tenant routing need exact app/shop pair |
| Pixel key | Store connection | Existing exact connection FK already provides this |
| Opportunity / checkout / order / attribution / revenue event | Store connection, plus tenant | Prevent one store's event from appearing as another store's recovery |
| Dashboard activity and revenue series | Store connection by default | Merchant dashboard is entered for a specific shop |
| Tenant membership and authorization | Tenant | User can be authorized for multiple stores in a tenant |
| MailerSend provider configuration | Tenant/provider by default | Provider credential is not a Shopify app credential |
| Sender profile, brand identity, recovery flow preferences | Explicit product choice; default store-scoped for separate independent shops | Existing writes are tenant-level and can unintentionally affect all shops |
| Billing subscription / usage charges | Store connection by default for Shopify-native billing; tenant roll-up for reporting | Shopify subscriptions are installed/managed per shop; exact billing policy and provider must be confirmed before migration |

If the business later chooses tenant-wide shared billing or settings, the API and dashboard must label those resources as tenant-wide. Do not present tenant-wide totals as store-specific values.

## 7. Required data model additions

Before writing migration SQL, inspect all constraints and foreign keys and determine whether to add explicit `shopify_connection_id` columns to Shopify-originated records, including opportunities, checkouts, orders/attributions, and revenue-ledger entries.

Do not rely solely on `metadata->>'shop_domain'` for long-term referential integrity. Metadata may remain for diagnostics, but store ownership should use a foreign key to the connection. Backfill only when an existing row can be mapped unambiguously; quarantine or leave unresolved rows requiring review rather than guessing.

For billing, determine whether existing measurements can be mapped to a store from their linked ledger/opportunity/order. Never attach an ambiguous tenant-level measurement to an arbitrary shop.

## 8. Required RPC/API contract changes

At minimum, review and update these families together:

- OAuth lifecycle: state creation/consumption, owner finalization, connect, disconnect, app state.
- Token lifecycle: refresh claim, completion, failure, Admin API token retrieval.
- Webhook lifecycle: HMAC verification, tenant/connection resolution, uninstall deactivation, privacy request handling.
- Control plane: dashboard summary, revenue series, settings, sender profile, billing summary/sync/status/usage claim/result.
- Recovery: candidate selection for cart/checkout/browse, delivery authorization, recovery context, next intervention scheduling, Shopify order/checkout lookup.
- Pixel: provisioning, ingestion, revocation.
- Merchant Edge Functions: dashboard, sender profile, recovery settings, email branding, and any other endpoint that resolves a user to a shop.

Avoid a partial rollout where Worker, n8n, Supabase verifier, OAuth, or refresh uses a different app identity contract.

## 9. Merchant store-selection contract

- Authenticate the Supabase user through Auth.
- Resolve all tenant memberships the user is authorized for.
- Return only active Shopify connections in those tenants.
- If one connection exists, it may be selected automatically.
- If multiple connections exist, require an explicit selection; do not return 403 merely because there is more than one and do not select the first row.
- Persist or pass the selected connection identifier in a server-validated way. Re-check that the connection belongs to one of the user's authorized tenants on every request.
- Never trust a raw client-supplied shop domain as proof of membership.
- For the control-plane service token, keep it server-only and bind internal authorization to the verified app identity and authorized connection, not just a global token plus caller-supplied shop header.

## 10. Rollout sequence (design only)

1. Freeze the legacy behavior contract and capture regression tests.
2. Add app registry and nullable app-key columns; backfill existing app connections and OAuth state history as `legacy` only where unambiguous.
3. Add app-aware RPCs alongside legacy wrappers. Legacy wrappers must be restricted to the legacy app and must fail closed if resolution is ambiguous.
4. Update OAuth install/callback and token refresh as a matched release.
5. Update Worker route/secret selection, n8n trusted app-key propagation, and Supabase HMAC/tenant resolver as one ingress release.
6. Update privacy and uninstall routes.
7. Update merchant store selection, dashboard scoping, recovery settings, sender profile, and branding APIs.
8. Update recovery candidate/event attribution to exact connection IDs; backfill only deterministic rows.
9. Decide and implement store-level billing or explicitly shared tenant billing, including subscription idempotency and reporting.
10. Run the complete regression matrix in an isolated environment, then request separate authorization for production rollout and Shopify app distribution.

## 11. Mandatory regression matrix

- Legacy install/callback/refresh/webhook/privacy/uninstall remains functional.
- Public app install/callback/refresh/webhook/privacy/uninstall uses only its own secret.
- Tampered HMAC, wrong app key, unknown app key, inactive app, mismatched app/shop, and spoofed internal header are rejected.
- Existing shop connection cannot be overwritten by another app.
- Two different stores in one tenant resolve to different connection IDs and never mix recovery events, revenue, dashboard activity, or credentials.
- Merchant user with multiple active stores can explicitly select each store; unauthorized store selection is rejected.
- Tenant-wide settings (if retained) are clearly shared; store-specific settings do not leak across stores.
- Uninstall one store does not deactivate another store, revoke its pixel key, or cancel shared billing while another eligible connection remains.
- Pixel key remains bound to exact connection.
- Checkout/cart/browse recovery, consent, suppression, delivery idempotency, attribution, and billing measurement regressions pass.
- No Shopify secret, access token, refresh token, service-role key, or control-plane token appears in client bundles, logs, or ordinary DB columns.

## 12. Explicit non-actions

This document is not executable SQL and is not an approval to change production. No database migration has been applied. No live function, secret, RLS policy, n8n workflow, Cloudflare Worker, Shopify app, or billing configuration has been changed. The current PR remains a draft preparation artifact.
