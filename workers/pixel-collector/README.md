# HENVALT Pixel Collector Worker

Tenant-scoped ingress for Shopify Web Pixel events. This is separate from the Shopify Admin webhook HMAC ingress.

## Routes

- `GET /health` — static health response; no database access.
- `POST /v1/events` — accepts only `page_viewed`, `product_viewed`, `product_added_to_cart`, and `checkout_started`.

## Cloudflare Worker bindings

- `SUPABASE_URL` — HENVALT Supabase project URL.
- `SUPABASE_PUBLISHABLE_KEY` — public project key used to call the Edge Function proxy.
- `COLLECTOR_SHARED_SECRET` — secret text binding used only by this Worker when calling the server-side proxy.
- `RATE_LIMITER` — Cloudflare rate-limit binding (120 requests/minute per digest+origin key).

**Never configure a Supabase service-role key in this Worker.** The service-role credential is held only by the `henvalt-pixel-ingest-proxy` Edge Function.

## Server-side ingestion path

1. Shopify Web Pixel sends an allowlisted event and its revocable public pixel key to this Worker.
2. The Worker validates and normalizes the event, strips URL query strings/fragments, hashes the public key, and applies Cloudflare rate limiting.
3. The Worker sends the digest, origin, normalized payload, and collector shared secret to `henvalt-pixel-ingest-proxy`.
4. The Edge Function validates the request and calls `public.henvalt_ingest_pixel_event` with its server-side service-role credential.
5. The database verifies the collector secret digest, active tenant-scoped pixel key, exact allowed origin, active Shopify connection, tenant state, event schema, and idempotency before writing the canonical event.

The public PostgREST RPC is not an anonymous browser-ingestion surface. Its execute permission is restricted to `service_role` and `postgres`; the Edge Function proxy is the only intended caller.

## Privacy and abuse controls

- Maximum request body: 12 KB at the collector; the proxy applies its own request limit.
- Only HTTPS origins are accepted, and the database requires an exact match against the pixel key's allowed origins.
- Pixel keys are stored as SHA-256 digests in the database and scoped to one Shopify connection.
- Event types are allowlisted; event IDs are idempotent.
- Page URLs are normalized to HTTPS origin + path; query strings and fragments are stripped before persistence.
- No email, phone, address, cookies, or Shopify customer ID is collected by this pixel.
- Cloudflare rate limiting is applied before the proxy; the database independently enforces a per-key minute limit.
- The public key is revocable and never grants Shopify Admin API access.
- Pixel activity is not proof of customer identity or marketing consent. Recovery and delivery must independently validate identity, explicit marketing consent, suppression, and eligibility.

## Separation from Shopify Admin webhooks

The pixel collector is not routed through Shopify HMAC verification. Shopify Admin webhooks use the separate signed ingress at `/shopify/webhooks`, which verifies Shopify's HMAC before forwarding to `HENVALT_INGEST`. Keep the existing three-workflow architecture; no fourth workflow is required.

## Remaining launch gates

1. Generate/confirm the official Shopify Web Pixel extension UID using Shopify CLI.
2. Deploy an unreleased Shopify app version, inspect the extension mapping, then release only after review.
3. Reauthorize the controlled test store to grant `write_pixels` and `read_customer_events`.
4. Confirm tenant-scoped pixel key provisioning and Shopify `webPixelCreate` / `webPixelUpdate`.
5. Verify a real storefront event in Supabase, including duplicate and checkout-session alias cases.
6. Confirm anonymous browse activity alone cannot trigger email recovery.
