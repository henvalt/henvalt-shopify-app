# HENVALT Pixel Collector Worker

This Worker is the tenant-authenticated ingress for Shopify Web Pixel events. It is separate from the Shopify Admin webhook HMAC path.

## Routes

- `GET /health` — health response only; no database access.
- `POST /v1/events` — accepts the four allowlisted Shopify pixel event types.

## Required bindings

Configure these in the new Worker only:

- `SUPABASE_URL` — HENVALT Supabase project URL (non-secret variable).
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase service-role key stored as a Cloudflare Worker secret. Never put it in source control, Shopify pixel settings, or a browser request.
- `RATE_LIMITER` — Cloudflare Workers Rate Limiting binding. The source fails closed if this binding is missing.

Use a dedicated Worker named `henvalt-pixel-collector`; do not overwrite `henvalt-api`, `henvalt-app`, `henvalt-clean-ingress-v1`, or `henvalt-dashboard-edge`.

## Database migration

The companion migration adds:

- `henvalt.pixel_keys`: stores only SHA-256 digests of revocable public pixel keys, tenant association, and exact allowed storefront origins.
- `henvalt.session_aliases`: maps a tenant-scoped checkout token to the anonymous Shopify browser client ID.
- `henvalt.bind_session_alias`: creates/refreshes the anonymous session and binds the checkout token atomically, refusing to rebind an existing token to a different session.
- An updated `henvalt.resolve_identity`: resolves exact session references first, then tenant-scoped aliases.

The migration is not applied automatically by this Worker. Review and apply it through Supabase migrations only after confirming the deployment configuration and rollback plan.

## Provisioning a tenant key

Generate a high-entropy random key server-side (at least 32 random bytes, base64url encoded). Give the plaintext key only to Shopify's pixel settings. Store only its lowercase SHA-256 hex digest in `henvalt.pixel_keys.key_digest`, with the tenant UUID and exact storefront origin(s), for example `https://store.example`.

Never accept `tenant_id` from the pixel payload. Tenant resolution comes exclusively from the digest lookup. Rotate by inserting a new digest and revoking the old row; do not reuse keys across tenants.

## Event handling and safety

- Payload is capped at 12 KB and event types are allowlisted.
- Only HTTPS origins listed on the key row are accepted.
- Cloudflare rate limiting is required.
- Browser events use the service-role key only inside the Worker.
- Browser events are recorded with no customer email or customer ID and with event class `OTHER`; they do not create recovery opportunities directly.
- `checkout_started` binds Shopify's checkout token to the anonymous client ID.
- The later signed Shopify checkout webhook retains its normal HMAC verification and can resolve the checkout token through the tenant-scoped alias.
- A pixel event never establishes customer identity or marketing consent. Existing recovery eligibility and delivery authorization must independently establish both before sending.
- The worker does not send email and does not bypass existing eligibility/consent gates.

## Current status

Source and migration are committed to the feature branch. This is not deployed. The migration has not been applied. No key is provisioned. Do not activate the Shopify pixel until all prerequisites, consent behavior, duplicate handling, and tenant isolation are tested.
