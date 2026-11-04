# HENVALT Web Pixel — integration scaffold

This extension subscribes to Shopify Web Pixel events:

- `page_viewed`
- `product_viewed`
- `product_added_to_cart`
- `checkout_started`

It sends a minimized event payload to a tenant-specific HTTPS collector. It does not collect customer email, phone, address, cookies, or raw query strings. The pixel remains inert unless both `collectorUrl` and `publicKey` are provisioned.

## Payload contract

Each event sends:

- `schema_version`, `event_id`, `event_type`, `occurred_at`
- `client_id`: anonymous browser/session reference only; never a customer identity
- `page_url`: origin + path only (no query string or fragment)
- `product`: minimal product and variant identifiers/title when present
- `cart_line`: quantity and merchandise identifier for add-to-cart events
- `checkout_reference`: checkout token only on `checkout_started`

The collector must treat `client_id` and `checkout_reference` as untrusted identifiers, not proof of customer identity or consent. Do not accept a tenant ID from this payload. Resolve tenant ownership only from the revocable pixel key.

## Identity bridge requirement

The existing `henvalt.sessions` table has a unique `(tenant_id, session_reference)` key, and the current `henvalt.resolve_identity(event_id)` function only matches an exact session reference. Shopify's checkout webhook currently uses the checkout token as its session reference, while the pixel has the browser `client_id`.

Before browse events can be joined to abandoned checkouts, HENVALT needs a tenant-scoped session-alias mapping (or equivalent atomic RPC) that links the checkout token to the anonymous browser session. The collector should:

1. Resolve the tenant from the presented pixel key.
2. Validate the event allowlist, payload size, origin policy, and applicable Shopify customer-privacy consent.
3. Create/update the anonymous session using `client_id` as its reference.
4. On `checkout_started`, bind `checkout_reference` to that session using an atomic, tenant-scoped alias operation.
5. Make `resolve_identity` consult that alias mapping when a signed Shopify checkout webhook arrives.
6. Handle webhook/pixel arrival in either order without cross-tenant links or silently merging unrelated sessions.
7. Keep anonymous sessions ineligible for email delivery until a trusted Shopify event establishes a customer and current marketing consent.

Do not store aliases in an unvalidated client-controlled tenant context, and do not pass browser pixel events through Shopify Admin webhook HMAC verification. Browser pixel events are not signed Admin webhooks.

## Required before deployment

Before deployment, run Shopify CLI's web-pixel extension scaffold/generation flow in the actual Shopify app project so Shopify generates and manages the required extension `uid`. This repository currently does not contain the root `shopify.app.toml` or a complete Shopify CLI app scaffold, so this branch is not independently deployable yet.

1. Add `write_pixels` and `read_customer_events` to the Shopify app's released configuration and OAuth scope allowlist.
2. Implement a tenant-scoped, revocable public pixel key. A public pixel key is not a secret and must be rate-limited, origin-checked where possible, and never grant Admin API access.
3. Implement the collector endpoint and the identity bridge described above.
4. Provision the endpoint and key in `webPixelCreate` settings after the merchant grants the required scopes.
5. Add a dedicated pixel event branch to the existing `HENVALT_INGEST` workflow or its existing ingress path. Keep the three-workflow architecture; do not create a fourth workflow.
6. Test in Shopify Customer Events / Pixel Helper, verify consent behavior, tenant isolation, duplicate handling, out-of-order delivery, and that no event creates an email recovery until customer identity and marketing consent are independently established.

## Important

This is an integration scaffold, not a deployed or activated pixel. Do not release it or claim browse-abandonment is active until the collector, key provisioning, identity bridge, OAuth scopes, app release, and merchant activation are all verified.
