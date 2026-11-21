# HENVALT exact-store privacy processing: lineage requirements

Status: read-only production audit + branch-only design. No production schema or data was changed.

## Why the V2 privacy inbox stops at REVIEW_REQUIRED

The current production privacy functions accept a tenant ID, Shopify customer ID and optional email. They do not accept a Shopify connection ID:

- `export_shopify_customer_data(p_tenant_id, p_shopify_customer_id, p_customer_email)` aggregates records across the tenant. It searches customer IDs and email addresses across tenant-level customers, checkouts, canonical events, delivery requests, messages, provider events, interventions, webhook payloads, errors, jobs and audit logs.
- `redact_shopify_customer_data(p_tenant_id, p_shopify_customer_id, p_customer_email)` deletes/anonymizes tenant-scoped events, checkouts, orders, sessions, messages, tracking data, provider data, suppression rows, webhook/error/job/audit payloads and the customer row. It has no exact-store predicate.
- `redact_shopify_shop_data(p_privacy_request_id)` reads the request's tenant ID and executes `DELETE FROM henvalt.tenants WHERE id = v_tenant_id`. It is tenant deletion, not one-Shop deletion.

These existing functions must not be called by the new per-app/per-store privacy inbox.

## Production column audit

A read-only inspection of the live schema found no `shopify_connection_id` column in these core tables:

| Table | Current store-lineage gap |
| --- | --- |
| `customers` | Tenant + Shopify customer ID/email only |
| `checkouts` | Tenant + Shopify checkout ID/token/session/email only |
| `orders` | Tenant + Shopify order ID/checkout/customer only |
| `sessions`, `session_aliases` | Tenant + session references only |
| `canonical_events` | Tenant + webhook parent/source/idempotency; no connection ID |
| `webhook_events` | Tenant + topic/source/idempotency; no connection ID |
| `opportunities` | Tenant + customer/checkout/source event only |
| `recovery_interventions` | Tenant + opportunity/sequence only |
| `delivery_requests`, `delivery_attempts` | Tenant + intervention/opportunity/recipient only |
| `customer_conversations`, `conversation_messages` | Tenant + customer/request/recovery references only |
| `messages`, `tracking_tokens`, `unsubscribe_tokens` | Tenant + customer/intervention references only |
| `email_suppressions`, `provider_events` | Tenant + email/provider/request references only |
| `processing_errors`, `background_jobs`, `audit_log` | Tenant + entity/payload/correlation only |
| `shopify_privacy_requests` | Shop domain and Shopify shop ID exist, but no app key or connection FK |

`pixel_keys` does have a Shopify connection reference, but the live pixel ingestion function currently discards that reference before writing canonical events. Therefore pixel history is not safely store-attributed downstream.

## Required target model

1. Treat `shopify_connections.id` as the immutable store boundary. The new app registry's `app_key` identifies which Shopify app installation owns that connection.
2. Add nullable `shopify_connection_id` (and, where useful, `app_key`) to every store-owned record listed above. Add composite foreign keys such as `(shopify_connection_id, tenant_id, app_key)` to the exact connection identity.
3. Make writers derive the connection only from trusted server-side webhook route tokens, verified webhook receipts, or stored pixel-key records. Never accept tenant or connection identity from browser payloads or an unsigned shop-domain header.
4. Change identity matching and idempotency from tenant-only to connection-qualified. Reused customer IDs, emails, checkout IDs, session references, delivery IDs and event IDs across two stores must not merge or suppress one another.
5. Carry the same connection identity through canonical events → customers/checkouts/orders/sessions → opportunities/recoveries → interventions/delivery/conversations/attribution/revenue.
6. Add a transactionally safe, exact-store privacy request processor that verifies app key + connection + shop domain + Shopify shop ID before reading or mutating data.

## Historical data policy

Do not backfill connection identity from `metadata.shop_domain` alone. The Shopify HMAC authenticates the raw body; the separate shop-domain header is not part of that HMAC. The earlier read-only lineage audit found 130 webhook receipts with a unique metadata-domain candidate, but this is not cryptographic proof of the historical route. Two receipts lacked a unique candidate. Historical pixel events have no reliable connection provenance because the old ingestion path discarded it. Keep unresolved history unresolved unless independent immutable provenance is found.

## Privacy operation gates

- **customers/data_request:** export only records with the exact verified connection ID. Do not widen to all tenant records when an ID is missing. A scoped email fallback may be used only after connection identity is fixed and ambiguity within that connection is handled explicitly.
- **customers/redact:** redact only records whose immutable connection ID matches the verified store and whose Shopify customer ID matches. Do not delete a tenant-wide customer row if another store still references that customer.
- **shop/redact:** delete/anonymize only records owned by that exact connection and app. Do not delete the tenant or other stores. Preserve a minimal, non-PII compliance receipt and audit evidence as legally appropriate.
- **all topics:** preserve durable delivery idempotency and a verified receipt; distinguish received/queued from processed/completed. Never return a completion status merely because the webhook was accepted.

## Current safe state

The new V2 privacy RPC verifies the raw-body HMAC using the app-specific Vault secret, checks payload shop domain and stored Shopify shop ID, resolves exact app + shop connection, and stores a minimal receipt. Every receipt remains `REVIEW_REQUIRED`. It stores no raw body or customer email and calls none of the existing tenant-wide export/redaction functions.

Public distribution remains blocked until the store-lineage migrations and writer changes are implemented and tested, exact-store export/redaction are implemented, and mandatory compliance webhook processing is end-to-end verified.
