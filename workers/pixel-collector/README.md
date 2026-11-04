# HENVALT Pixel Collector Worker

Tenant-keyed ingress for Shopify Web Pixel events. This is separate from the Shopify Admin webhook HMAC ingress.

## Routes

- `GET /health` — static health response; no database access.
- `POST /v1/events` — accepts only `page_viewed`, `product_viewed`, `product_added_to_cart`, and `checkout_started`.

## Bindings

- `SUPABASE_URL` — HENVALT Supabase project URL.
- `SUPABASE_PUBLISHABLE_KEY` — public project key; this Worker invokes only `public.henvalt_ingest_pixel_event`.
- `RATE_LIMITER` — Cloudflare rate-limit binding (120 requests/minute per digest+origin key).

**Never configure a Supabase service-role key in this Worker.** The database tables are not granted to `anon`; the public wrapper is the only browser-ingestion surface.

## Current deployment

- Worker: `henvalt-pixel-collector`
- URL: `https://henvalt-pixel-collector.chmuhammadrehan18.workers.dev`
- Active version: `e8b331a5-461b-4db3-9f5c-4789f11cd106` (100% traffic)
- Deployment: `04248d80-b768-421f-9334-ea36460e14ab`
- Health route has not yet been externally smoke-tested from this runtime.

## Database foundation

The following migrations are applied to the live Supabase project:

- `pixel_keys`: SHA-256 digest only, tenant association, exact allowed origins, active/revoked state.
- `pixel_rate_limits`: bounded per-key minute counter.
- `session_aliases`: tenant-scoped checkout-token-to-anonymous-session mapping.
- `bind_session_alias`: atomic alias binding; refuses to rebind an existing checkout token to another session.
- `ingest_pixel_event` and `public.henvalt_ingest_pixel_event`: validate the digest, tenant state, origin, payload, event type and idempotency; write canonical events and resolve anonymous identity.
- `resolve_identity`: consults the tenant-scoped alias mapping.

The three internal tables have RLS enabled, no client policies, and table grants only for `service_role` and `postgres`. The public ingestion wrapper has EXECUTE grants for `anon`, `service_role`, and `postgres`; `authenticated` and `PUBLIC` are not granted.

## Privacy and abuse controls

- Maximum request body: 12 KB.
- Only HTTPS origins are accepted, and the database requires an exact origin match against the tenant key row.
- Event types are allowlisted; event IDs are idempotent.
- Page URLs are normalized to HTTPS origin + path; query strings and fragments are stripped both in the pixel and again at the collector.
- No email, phone, address, cookies, or Shopify customer ID is collected by this pixel.
- Cloudflare rate limiting is applied before the database call; the database independently enforces a per-key global minute limit.
- Cloudflare Worker observability has query-string redaction enabled.
- The public key is revocable and tenant-scoped; it never grants Admin API access.
- A pixel event never establishes customer identity or marketing consent. Recovery and delivery must independently validate identity, explicit marketing consent, suppression and eligibility.

## Data path

The Worker currently writes directly to the narrow Supabase RPC. It has not been routed through the Shopify-signed webhook branch or added as a separate branch inside `HENVALT_INGEST`. Do not send pixel events through Shopify HMAC verification. Keep the three-workflow architecture; no fourth workflow is needed.

## Remaining launch gates

1. Generate the official Shopify extension UID using Shopify CLI.
2. Deploy an unreleased Shopify app version, inspect the mapping, then release after review.
3. Reauthorize the test store to grant `write_pixels` and `read_customer_events`.
4. Provision a tenant key with the exact store origin and activate the pixel with `webPixelCreate`.
5. Verify a real event in Supabase, including duplicate and out-of-order checkout alias cases.
6. Confirm no browse-only anonymous event can trigger email.
