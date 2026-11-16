const SHOPIFY_FORWARD_HEADERS = [
  "content-type",
  "x-shopify-shop-domain",
  "x-shopify-topic",
  "x-shopify-hmac-sha256",
  "x-shopify-webhook-id",
  "x-shopify-event-id",
];

/**
 * Build a clean upstream header set only after the caller has verified the
 * Shopify HMAC over the untouched request body.
 *
 * Deliberately excludes Authorization, Cookie, forwarded identity headers,
 * arbitrary X-Henvalt-* values, and all other caller-controlled metadata.
 */
export function buildVerifiedWebhookHeaders(request) {
  const headers = new Headers();
  for (const name of SHOPIFY_FORWARD_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  return headers;
}
