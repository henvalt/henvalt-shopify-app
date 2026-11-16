# App-aware Shopify OAuth handoff — preparation contract

Status: branch-only engineering specification. No production schema, OAuth function,
Worker, Shopify subscription, or active workflow is changed by this document.

## Why this boundary exists

The live `henvalt-shopify-oauth` Edge Function currently reads one global
`SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET`. Its OAuth state stores the shop,
expiry, consumption state, and initiating merchant user, but no app identity.
The live finalizer
`control_plane_finalize_shopify_oauth_install_expiring_for_owner` accepts the
state hash and shop/token data, then calls `control_plane_connect_shop(shop)`.
That connection resolver selects by shop domain only and returns a connection
ID; it has no app identity input.

Therefore a per-install webhook route token must not be issued until the OAuth
state and finalization transaction are bound to a registered app identity.

## Required identity derivation

1. The OAuth server derives the app identity from the configured Shopify client
   ID by looking up exactly one active `shopify_app_registry` row whose
   `shopify_client_id` equals that configured client ID.
2. The caller/browser must never choose or submit `app_key`.
3. Zero or multiple matching registry rows fail closed. No legacy/default
   identity fallback is permitted in V2 mode.
4. Persist the resolved `app_key` into the server-created OAuth state.
5. The callback verifies Shopify HMAC using the matching app secret and then
   verifies the returned state belongs to the same shop, user, and app.
6. The finalization transaction must atomically bind the exact connection to
   that `app_key`, and reject an existing connection already bound to a
   different app. It must not reassign an existing connection silently.
7. Only after the app-bound connection is confirmed may a per-install route
   token be generated with `crypto.getRandomValues(new Uint8Array(32))`.
   Persist only SHA-256(token); return the raw token once to the server-side
   OAuth function for callback registration. Never log or persist raw token.
8. V2 webhook subscription registration is gated by a server-side feature flag
   defaulting to false. With the flag false, preserve the existing legacy
   callback and existing registration verification behavior exactly.

## Required data contract

- `shopify_oauth_states.app_key`: nullable during transition; new app-aware
  OAuth states require a non-null registry key.
- `shopify_connections.app_key`: nullable for historical connections until
  identity is independently established. Never backfill by guess.
- `shopify_app_registry`: server-only mapping from app key to unique Shopify
  client ID and Vault secret reference. The secret reference is not secret
  material and must resolve only inside trusted server/database code.
- `shopify_webhook_route_tokens`: store connection, tenant, app key, token
  hash, timestamps, and revocation state. Never store the route token itself.

## Compatibility and rollout

- Legacy OAuth stays on the current callback while V2 is disabled.
- Do not infer app identity from shop domain, tenant, user, or current webhook
  destination.
- Existing connections with null app identity remain unresolved until proven.
- The merchant-owned legacy app and a future Partner-owned public app must be
  distinct registry entries with distinct client IDs and Vault secret refs.
- The public app entry must not be seeded until its actual Shopify client ID
  and secret have been provisioned through the approved process.
- Do not switch existing webhook subscriptions until route-token provisioning,
  verified inbox persistence, duplicate handling, inbox consumption, and
  rollback have passed non-production tests.

## Acceptance tests before enabling V2

1. A configured client ID maps to exactly one active app registry row.
2. Unknown and ambiguous client IDs fail closed before OAuth state creation.
3. Browser-supplied `app_key` cannot influence app selection.
4. OAuth state app identity survives callback and is checked against the
   callback's configured client ID.
5. Wrong-shop, wrong-user, consumed, expired, or wrong-app state is rejected.
6. A connection with null app identity can be assigned only through an
   authorized, atomic finalization path.
7. A connection bound to app A cannot be rebound to app B.
8. Route tokens contain at least 256 bits of entropy; only the SHA-256 hash is
   persisted; raw token never appears in logs or database rows.
9. Reauthorization rotates/revokes route tokens safely and does not create
   duplicate webhook subscriptions.
10. V2 disabled means the existing legacy callback remains unchanged.
11. V2 enabled registers only the per-install callback for the exact
    app-bound connection.
12. No OAuth success response is returned if required app identity or route
    token persistence fails.

## Explicitly not done

No migration has been applied. No app registry row has been inserted. No
existing connection has been assigned an app key. No route token has been
created. No OAuth code or live configuration has been changed. No webhook
subscription has been switched. This specification is not proof of an
end-to-end working installation.
