# App-aware Shopify privacy webhook inbox (V2)

Status: branch-only candidate. Nothing is deployed or applied.

## Why this is required

The current privacy Edge Function uses one global Shopify secret and resolves a shop to a tenant. Its shop-redaction path calls a tenant-level deletion RPC. That is not safe for a tenant containing multiple Shopify stores.

## Proposed V2 contract

- The app's Shopify compliance webhook URI contains a fixed app key, for example:
  `https://<project>.supabase.co/functions/v1/henvalt-shopify-privacy-v2/<app-key>`.
- The Edge Function accepts only the three mandatory compliance topics and forwards exact raw bytes and allowlisted headers to a service-role-only database RPC.
- The RPC resolves exactly one active app registry row by app key + configured Shopify client ID, reads the app-specific secret internally from Vault, and verifies HMAC-SHA256 over the raw request body.
- It requires the payload shop domain to match the signed request's shop-domain header.
- It resolves a connection only by exact app key + exact shop domain. It never falls back to tenant membership.
- When a linked connection has a stored immutable Shopify shop ID and the signed payload includes `shop_id`, both must match; mismatches are rejected.
- It stores a minimal receipt: app, optional exact connection, shop, topic, webhook ID, customer ID, data-request ID, body digest, verification timestamp and status. It does not store raw payload or customer email.
- Duplicate delivery is idempotent by app + shop + webhook ID.

## Deliberate safety boundary

A successful HTTP 200 means the verified compliance request is durably recorded. It does **not** claim export or deletion is complete. Every receipt remains `REVIEW_REQUIRED` until exact-store customer export/redaction and exact-store shop-redaction functions have passed independent multi-store tests. The old tenant-wide redaction RPC is never called.

## Activation prerequisites

1. Register each Shopify app in `shopify_app_registry` with the matching client ID and Vault secret reference.
2. Configure the corresponding app's compliance webhook URI with its app key.
3. Apply migrations only after disposable-database replay and SQL tests pass.
4. Deploy the Edge Function only after explicit production approval.
5. Implement exact-store export/redaction RPCs and a reviewed processor before moving any receipt out of `REVIEW_REQUIRED`.

The existing `shopify.app.toml` and live privacy function remain unchanged.
