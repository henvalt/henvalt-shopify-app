# HENVALT Pixel Collector Worker

This Worker is the tenant-authenticated ingress for Shopify Web Pixel events. It is separate from the Shopify Admin webhook HMAC path.

## Routes

- `GET /health` — health response only; no database access.
- `POST /v1/events` — accepts the four allowlisted Shopify pixel event types.

## Required bindings

Configure these in the new Worker only:

- `SUPABASE_URL` — HENVALT Supabase project URL (non-secret variable).
- `SUPABASE_PUBLISHABLE_KEY` — the project's publishable key. This key is designed for public clients; the Worker calls only the narrowly scoped `public.henvalt_ingest_pixel_event` RPC. Never put a Supabase service-role key in this Worker.
- `RATE_LIMITER` — Cloudflare Workers Rate Limiting binding. The source fails closed if this binding is missing.

Use a dedicated Worker named `henvalt-pixel-collector`; do not overwrite `henvalt-api`, `henvalt-app`, `henvalt-clean-ingress-v1`, or `henvalt-dashboard-edge`.

The `wrangler.toml.example` file defines the Worker and rate-limit binding. Choose a unique positive integer namespace ID in the Cloudflare account. Install Wrangler 4.36.0 or later. Set `SUPABASE_SERVICE_ROLE_KEY` with `wrangler secret put`; never put it in TOML.

## Database migration

The companion migration adds:

- `henvalt.pixel_keys`: stores only SHA-256 digests of revocable public pixel keys, tenant association, and exact allowed storefront origins.
- `henvalt.session_aliases`: maps a tenant-scoped checkout token to the anonymous Shopify browser client ID.
- `henvalt.bind_session_alias`: creates/refreshes the anonymous session and binds the checkout token atomically, refusing to rebind an existing token to a different session.
- `public.henvalt_ingest_pixel_event`: the only public RPC exposed for pixel ingestion; validates the revocable key and exact origin, applies a database-level per-key limit, writes an idempotent canonical event, resolves the anonymous session, and binds checkout aliases.
- An updated `henvalt.resolve_identity`: prefers tenant-scoped aliases over an exact checkout-token session, so webhook-first and pixel-first arrival order both resolve to the same anonymous browser session.

The migration is not applied automatically by this Worker. Review and apply it through Supabase migrations only after confirming the deployment configuration and rollback plan.

## Provisioning a tenant key

Generate a high-entropy random public pixel key server-side (at least 32 random bytes, base64url encoded). Give the plaintext key only to Shopify's pixel settings. Store only its lowercase SHA-256 hex digest in `henvalt.pixel_keys.key_digest`, with the tenant UUID and exact storefront origin(s), for example `https://store.example`.

Never accept `tenant_id` from the pixel payload. Tenant resolution comes exclusively from the digest lookup. Rotate by inserting a new digest and revoking the old row; do not reuse keys across tenants.

## Event handling and safety

- Payload is capped at 12 KB and event types are allowlisted.
- Only HTTPS origins listed on the key row are accepted.
- The pixel sends a public/revocable key in the JSON body using `text/plain;charset=UTF-8` to avoid a browser CORS preflight. The Worker returns an exact-origin CORS header only after validating the key and origin.
- Cloudflare rate limiting is applied before the database call; limits are approximate per Cloudflare location. The database RPC also enforces a per-key global minute bucket limit.
- The Worker uses only the Supabase publishable key. The service-role key is never placed in Worker configuration.
- Browser events are written through the narrow public RPC into the existing canonical-event ledger with no customer email or customer ID and event class `OTHER`; they do not create recovery opportunities directly. This collector currently writes to Supabase directly; it has not yet been added as a dedicated branch inside the existing `HENVALT_INGEST` n8n workflow.
- `checkout_started` binds Shopify's checkout token to the anonymous client ID.
- The later signed Shopify checkout webhook retains its normal HMAC verification and can resolve the checkout token through the tenant-scoped alias.
- A pixel event never establishes customer identity or marketing consent. Existing recovery eligibility and delivery authorization must independently establish both before sending.
- The worker does not send email and does not bypass existing eligibility/consent gates.

## Current status

Source, migrations, and Wrangler template are committed to the feature branch. The session-alias migration is applied to Supabase; the public pixel-ingest RPC migration is not yet applied. This Worker is not deployed. No pixel key is provisioned. The collector is not connected to the existing n8n ingestion workflow yet. Do not activate the Shopify pixel until all prerequisites, consent behavior, duplicate handling, and tenant isolation are tested.
