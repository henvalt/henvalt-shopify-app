# Shopify ingress Worker deployment reconciliation

**Status:** source hardening candidate; not deployed  
**Live Worker:** `henvalt-clean-ingress-v1`  
**Webhook path:** `POST /shopify/webhooks`  
**Configured upstream:** `https://n8n.henvalt.com/webhook/henvalt/ingest`

## Live configuration inspected

Read-only Cloudflare inspection confirmed:

- The Worker exists in the connected Cloudflare account.
- `N8N_INGEST_URL` is configured to the HENVALT production ingest webhook.
- `SHOPIFY_API_SECRET` is a secret binding. Its value was not read or copied.
- Worker Logs and persisted invocation logs are enabled.
- The HENVALT OAuth callback's audit record for the test tenant confirms all 12 expected Shopify webhook topics were registered and re-read as verified against this Worker URL on 2026-11-13.

The deployed Worker verifies Shopify HMAC-SHA256 over the raw request body before forwarding. It forwards a whitelist of Shopify headers and the original body to n8n, and returns a gateway error when forwarding fails.

## Source drift found

The deployed script and tracked `cloudflare/worker.js` were not identical. The deployed script had explicit missing-binding checks, a network-error boundary, and upstream failure handling. The tracked source had a 1 MB limit but forwarded all request headers and did not catch network failures.

This branch reconciles the source with the live route and failure behavior, while adding:

- A bounded streaming body reader with a 5 MB maximum, including chunked requests without Content-Length.
- HMAC verification over the exact raw bytes, not parsed/re-serialized JSON.
- Strict shop-domain and webhook-header validation.
- An allowlist of forwarded Shopify headers; arbitrary cookies and Authorization headers are not forwarded.
- Fail-closed configuration checks and explicit retryable 502 responses for upstream network/non-2xx failures.
- Injectable fetch handling and isolated Deno tests for route validation, HMAC, raw-byte preservation, header filtering, body-size limits and upstream failures.

## Deployment boundary

No live Worker, binding, secret, Shopify webhook subscription, n8n workflow or Supabase object was changed. The new source is a draft pull request only. Do not deploy until the tests run in CI and the live route has a controlled signed-webhook verification. Do not replace the live secret binding.


## Payload-size contract

The Worker enforces a 5,000,000-byte streaming cap for HTTPS webhook deliveries. Shopify's current delivery documentation lists a 5 MB payload limit for HTTPS destinations (separate from the 1 MB Amazon EventBridge limit). This keeps the Worker bounded without rejecting valid HTTPS deliveries solely because they exceed 1 MB. See https://shopify.dev/docs/apps/build/events/delivery-structure.
