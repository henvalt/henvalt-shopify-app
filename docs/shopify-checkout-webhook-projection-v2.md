# Verified Shopify checkout webhook adapter V2

**Status:** branch-only candidate; not applied or deployed.
**Depends on:** candidate migrations 001, 002 and 009.

## Why token-first

Shopify's 2026-04 API version removed `id` from `checkouts/create` and `checkouts/update`. Shopify directs apps to use the checkout `token`. A checkout's token is therefore the required exact-store external reference. The legacy numeric/string ID is optional for older payloads only.

## Flow

1. The existing V2 ingress verifies the raw-body Shopify HMAC using the app-specific Vault secret and binds the receipt to the hashed per-install route token, app, connection and shop domain.
2. The Edge Function retains the exact raw bytes for the duration of the request.
3. After the verified inbox RPC accepts the receipt, the Edge Function calls `project_verified_shopify_checkout_v2` with the same route token, delivery ID and raw bytes.
4. The projection RPC resolves the same installation and exact receipt, then compares the supplied raw-body SHA-256 digest with the digest stored only after HMAC verification. It does not trust caller-supplied tenant or connection IDs.
5. For `checkouts/create` and `checkouts/update`, it upserts checkout identity by (connection, checkout token), links an optional Shopify customer reference only within the same connection, and stores only total/currency/completion metadata. It orders updates by Shopify's source `updated_at`; an older delivery is recorded as processed but cannot overwrite newer checkout state. Events without a source timestamp cannot overwrite a row that already has one. It does not store email, phone, address, line items or raw payload.
6. The verified receipt is marked PROCESSED only after projection. If the required token is missing, the receipt is quarantined as REJECTED with a safe review code; no checkout identity is created.

The edge ingress calls the projection on retries too. This allows a previously accepted receipt to complete projection after a transient RPC failure. Projection is idempotent by exact connection + checkout token.

## Security and isolation

- Service-role-only RPC; fixed empty search path and schema-qualified references.
- Route token hash resolves the installation; delivery ID lookup is scoped to that same connection.
- Body digest must exactly match the already-HMAC-verified receipt.
- The checkout token can be reused by another store without collision.
- Customer identity is pseudonymous and exact-store scoped. No email matching or cross-store fallback.
- V1 webhook, customer, checkout, canonical event and recovery writers remain untouched.
- No downstream recovery/delivery/attribution/billing consumer reads this V2 table yet.

## Explicit limitations

This stage only projects checkout token, optional legacy ID, optional customer ID, total, currency and completion state. It does not persist email/contactability or line items, and therefore is not yet a complete abandoned-checkout recovery pipeline. A separately reviewed, consent/purpose-aware protected-contact design and store-aware recovery readers are still required.
