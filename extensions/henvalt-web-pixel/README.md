# HENVALT Web Pixel — integration scaffold

This extension subscribes to Shopify Web Pixel events:

- `page_viewed`
- `product_viewed`
- `product_added_to_cart`
- `checkout_started`

It sends a minimized event payload to a tenant-specific HTTPS collector. It does not collect customer email, phone, address, cookies, or raw query strings. The pixel remains inert unless both `collectorUrl` and `publicKey` are provisioned.

## Required before deployment

1. Add `write_pixels` and `read_customer_events` to the Shopify app's released configuration and OAuth scope allowlist.
2. Implement a tenant-scoped, revocable public pixel key in HENVALT. A public pixel key is not a secret and must be rate-limited, origin-checked where possible, and never grant Admin API access.
3. Implement the collector endpoint. It must validate the key, resolve the tenant from the key (never trust a tenant ID supplied by the browser), enforce payload size and event allowlists, apply consent/privacy policy, and enqueue events idempotently.
4. Provision the endpoint and key in `webPixelCreate` settings after the merchant grants the required scopes.
5. Add a dedicated pixel event branch to the existing `HENVALT_INGEST` workflow or its existing ingress path. Do not pass browser events through Shopify webhook HMAC verification; browser pixel events are not Shopify Admin webhooks.
6. Test in Shopify Customer Events / Pixel Helper, verify consent behavior, tenant isolation, duplicate handling, and that no event creates an email recovery until customer identity and marketing consent are independently established.

## Important

This is an integration scaffold, not a deployed or activated pixel. Do not release it or claim browse-abandonment is active until the collector, key provisioning, OAuth scopes, app release, and merchant activation are all verified.
