# Shopify webhook trust boundary: Cloudflare Worker → n8n → Supabase

Status: preparation-branch design based on the active production workflow and live Supabase function definitions. This document does not authorize a production cutover.

## Decision: reuse the existing Shopify HMAC trust boundary

A second Worker-to-n8n HMAC secret and n8n Crypto credential are unnecessary for Shopify webhook ingress. HENVALT already has an independent, server-side Shopify HMAC verification step backed by Supabase Vault.

Verified live facts:
- Active n8n workflow: `HENVALT_INGEST`, ID `VTpfGKNtu1CSQ4Rv`, 51 nodes; active version `6368d539-708f-494a-8be8-b9601d0e8607`.
- The webhook is POST `/henvalt/ingest`, Webhook v2.1, `rawBody: true`, `responseMode: onReceived`.
- The live path is `Event Webhook → Validate & Normalize → Engine Config → Verify Shopify HMAC → HMAC Verified? → Resolve Shopify Tenant`.
- The `Verify Shopify HMAC` HTTP Request calls `henvalt.verify_shopify_webhook_hmac(p_hmac, p_raw_body_base64)`.
- The live SQL definition of that function reads the secret named `henvalt_shopify_app_secret` from `vault.decrypted_secrets`, computes HMAC-SHA256 over `decode(p_raw_body_base64, 'base64')`, and compares the supplied signature. It returns false on missing or malformed inputs.
- The false output of `HMAC Verified?` is unconnected. Tenant resolution and the ingest/business path are reachable only after HMAC verification succeeds.
- The existing `henvalt.ingest_raw_webhook_v2` function locks by tenant plus Shopify source event ID/idempotency key. It blocks already-processed events and recent in-flight events, and only reclaims eligible stale work. This is the existing durable event-idempotency mechanism; a second request-ID table is not needed for this Shopify webhook path.

## Required trust chain

```text
Shopify
  → Cloudflare Worker
      → verify Shopify HMAC over exact raw bytes
      → forward allowlisted Shopify headers + unchanged raw body
  → n8n Event Webhook (rawBody enabled)
      → Validate & Normalize (captures original binary body as Base64)
      → Engine Config
      → Supabase verify_shopify_webhook_hmac
          → read henvalt_shopify_app_secret from Supabase Vault
          → HMAC-SHA256 over exact decoded raw bytes
      → HMAC Verified?
          false → stop
          true → resolve shop → tenant
                → ingest_raw_webhook_v2 (durable idempotency)
                → existing processing graph
```

The Worker performs an early authenticity check; n8n independently verifies the same Shopify signature against the Vault-held secret before tenant resolution or business writes. The Worker must forward the original request bytes unchanged and only the allowlisted Shopify headers. Caller-supplied Authorization, Cookie, X-Henvalt identity, and tenant headers remain stripped.

## Secret handling

- Reuse the existing Vault secret `henvalt_shopify_app_secret`; do not create a duplicate Worker-hop HMAC secret.
- The Cloudflare Worker binding `SHOPIFY_API_SECRET` and the Vault secret `henvalt_shopify_app_secret` must represent the same Shopify app secret for the active app identity. Their values were not read or compared during this audit.
- Do not return, print, copy, or expose the Vault secret. The existing SECURITY DEFINER verifier is the narrow read boundary.
- No n8n Crypto credential or Header Auth credential is required for this design.
- The Worker still needs its existing `SHOPIFY_API_SECRET` and `N8N_INGEST_URL` bindings. This branch does not configure or deploy either binding.

## Worker implementation contract

The preparation-branch Worker:
1. Validates required Shopify metadata headers.
2. Reads the request body once as exact bytes, with a 1 MB cap.
3. Verifies Shopify HMAC-SHA256 before forwarding.
4. Forwards only `content-type`, `x-shopify-shop-domain`, `x-shopify-topic`, `x-shopify-hmac-sha256`, `x-shopify-webhook-id`, and `x-shopify-event-id`.
5. Forwards the exact unchanged body bytes.
6. Does not add an internal HMAC, request-ID signature, or static n8n auth header.

This avoids the inaccessible manual n8n credential setup and removes a redundant secret lifecycle. The old helper `worker-to-n8n-auth.mjs` is not part of the selected Shopify webhook trust chain.

## Acknowledgement and failure semantics

The current webhook uses `responseMode: onReceived`. It acknowledges receipt before the downstream Supabase HMAC check completes. A 200 response from n8n therefore means the webhook execution was accepted by the trigger, not that HMAC verification or business processing succeeded. The Worker must not interpret this early acknowledgement as proof of recovery processing. A future response-mode change requires separate Shopify retry and latency testing.

The Worker itself rejects invalid Shopify HMAC before forwarding. If the Vault secret and Worker binding drift, the Worker may accept a request that n8n later rejects; the two app-secret configurations must be reconciled before production cutover.

## Verified and unverified

Verified:
- Live n8n node order places Supabase HMAC verification before tenant resolution and ingest.
- Live `henvalt.verify_shopify_webhook_hmac` reads the named secret from Vault and verifies exact raw body bytes.
- Live `henvalt.ingest_raw_webhook_v2` already provides durable event idempotency and duplicate/in-flight suppression.
- The branch Worker implementation now relies on the existing Shopify HMAC contract and removes the extra n8n credential requirements.
- Static Worker tests cover raw-byte forwarding, header allowlisting, and rejection of invalid Shopify HMAC.

Not verified:
- The Cloudflare Worker binding `SHOPIFY_API_SECRET` equals the current Vault secret value; values were deliberately not exposed or compared.
- A new end-to-end webhook request has not been sent through the deployed Worker and active n8n workflow.
- Current production Worker has not been changed.
- No n8n workflow, Supabase schema/function, Vault secret, Shopify app, or release was changed.

## Cutover gates

Before any production deployment:
1. Verify, without displaying either value, that the Worker Shopify secret and Vault secret are the same active app secret.
2. Run the branch CI tests.
3. Exercise a known valid webhook and a one-byte-mutated body against a non-production route/test harness.
4. Confirm valid signature reaches the existing idempotent ingest path and invalid signature cannot reach tenant resolution or writes.
5. Keep the active production Worker and n8n workflow unchanged until separately approved.
