# Active Runtime Store-Identity Audit (Read-Only)

**Status:** review evidence captured 2026-11-16. No production resources were modified.
**Scope:** deployed Supabase Edge Function source, active n8n workflow definitions, deployed Cloudflare Worker source/settings, and live PostgreSQL trigger inventory.
**Purpose:** identify the remaining identity and tenant/store-scope gaps before designing a safe public Shopify app rollout.

## Executive findings

1. **There is one active Shopify app identity in the deployed OAuth and webhook ingress path.** The deployed OAuth function (v27) reads one global `SHOPIFY_API_KEY` / `SHOPIFY_API_SECRET`; OAuth state stores the shop and initiating user but no stable app key. The callback exchanges the code using that same global pair and finalizes by shop domain.
2. **The deployed ingress Worker is single-secret and single-route.** Live Worker `henvalt-clean-ingress-v1` accepts `POST /shopify/webhooks`, validates raw-body HMAC using `env.SHOPIFY_API_SECRET`, then forwards to the single HENVALT_INGEST webhook. It has no app-key route or trusted app-identity context. Its current settings expose one public app client ID as plain text and one Shopify secret binding (secret value not read).
3. **The active HENVALT_INGEST workflow re-verifies HMAC but then resolves only a tenant by shop domain.** Its downstream canonical-event, customer, checkout, opportunity, order projection, attribution, recovery-stop, consent, and ledger calls do not carry `shopify_connection_id`. Shop domain is copied into metadata, not used as the relational identity key for all business rows.
4. **Recovery and delivery workers are also tenant/opportunity-centred.** HENVALT_RECOVERY uses scheduled SQL candidate processors and intervention context by intervention ID. HENVALT_DELIVERY authorizes by tenant and recovery lineage; the AI reply context joins tenant/customer/conversation lineage but does not independently enforce an exact Shopify connection.
5. **The merchant dashboard and settings Edge Functions fail closed when a user has more than one active store.** The merchant dashboard requires exactly one tenant membership and exactly one active Shopify connection. Sender profile, email branding, and recovery settings repeat the one-tenant/one-shop assumption. This is safer than silently selecting a store, but it blocks multi-store merchants and must be replaced by explicit store selection.
6. **Privacy and unsubscribe paths require connection-aware semantics.** Privacy export is tenant-filtered; deployed Shopify privacy handler v1 has one global secret and shop-domain lookup, and the prior source audit found tenant-wide shop redaction. Unsubscribe token processing calls tenant-level functions; the token/recipient lineage must be traced to the originating store before deciding whether suppression is store-scoped or tenant-wide.
7. **The exact live trigger inventory is five user-defined triggers**, not six. This corrects the earlier draft count.

## Live deployed Edge Function inventory

Versions and SHA-256 identifiers below were returned by the Supabase Edge Functions listing on 2026-11-16. These are live deployed versions, not repository versions.

| Function | Live version | Relevant observation |
|---|---:|---|
| `henvalt-shopify-oauth` | 27 | One global Shopify key/secret; OAuth state has no app key; finalization is shop-domain based. |
| `henvalt-shopify-token-refresh` | 1 | One global key/secret; claim/complete/fail RPCs use shop domain only. |
| `henvalt-control-plane` | 24 | Bearer control-plane token plus `x-henvalt-shop`; RPC calls are shop-domain based, not app-key based. |
| `henvalt-merchant-dashboard` | 4 | Requires exactly one tenant membership and exactly one active connection. |
| `henvalt-dashboard` | 1 | Shopify embedded-session JWT is checked against one global Shopify API key/secret; dashboard RPC receives shop domain. |
| `henvalt-pixel-ingest-proxy` | 3 | Calls `henvalt_ingest_pixel_event`; database pixel key already binds to exact `shopify_connection_id` (preserve this stronger identity model). |
| `henvalt-merchant-sender-profile` | 7 | Requires one tenant and one active shop; resolves settings by shop domain. |
| `henvalt-merchant-email-branding` | 2 | Requires one tenant and one active shop; branding RPC uses shop domain. |
| `henvalt-merchant-recovery-settings` | 2 | Requires one tenant and one active shop; preferences are read/written by shop domain. |
| `henvalt-public-mail-actions` | 4 | Tracking and unsubscribe actions use token-based RPCs; store scope must follow token lineage. |
| `henvalt-privacy-export` | 1 | User-facing export/status endpoints are tenant-scoped; privacy request selection filters by tenant. |
| `henvalt-shopify-privacy` | 1 | Recovered deployed source separately; one global Shopify secret and tenant-only privacy RPC contract remain unsafe for multi-store deletion. |

## Active n8n workflow findings

### HENVALT_INGEST

Active version: `6368d539-708f-494a-8be8-b9601d0e8607` (51 nodes).

- Webhook receives raw body; normalization extracts Shopify shop domain/topic/webhook ID and raw-body base64.
- `verify_shopify_webhook_hmac(p_hmac,p_raw_body_base64)` verifies signature without an app identity argument.
- `resolve_shopify_tenant(p_shop_domain)` returns tenant context only.
- `ingest_raw_webhook_v2`, `upsert_canonical_event`, `resolve_identity`, `upsert_customer`, `upsert_checkout`, `create_opportunity_idempotent`, order projection/attribution/stop/ledger, and consent update calls do not include a connection ID.
- Shop domain is present in metadata on webhook/customer/checkout/consent records, but metadata is not a substitute for a connection FK and matching constraints.
- Direct payment-order lookup filters by tenant + Shopify order ID; it does not include a connection ID.

### HENVALT_RECOVERY

Active version: `32e50bf7-4cbd-4070-bbba-f259ed17b369` (46 nodes).

- Scheduled candidate processors: `process_browse_abandonment_candidates`, `process_abandoned_cart_candidates`, and `process_abandoned_checkout_candidates`.
- Worker context is loaded by intervention ID; recovery/intervention/delivery creation is based on opportunity/recovery IDs.
- Shopify token refresh discovery scans active connections and calls refresh by shop domain only.
- Candidate discovery must return an authoritative connection ID and quarantine records with missing or ambiguous lineage; a worker should not infer a store from tenant membership or current active connections.

### HENVALT_DELIVERY

Active version: `621ae6ce-a006-4fed-a70e-acf774c360fb` (62 nodes).

- `authorize_delivery_request` receives tenant, delivery request, intervention, recovery, opportunity, recipient and idempotency key, but no explicit connection ID.
- Inbound MailerSend replies resolve conversation context from tenant/customer/conversation/delivery lineage. The AI context query does not independently join through a Shopify connection.
- Tracking and unsubscribe actions use opaque tokens; keep tokens globally unguessable, but bind each token to its exact originating delivery/connection and enforce the chosen suppression policy.
- MailerSend provider credentials should remain tenant/provider-scoped; do not conflate them with Shopify app secrets.

## Live Cloudflare Worker evidence

Worker: `henvalt-clean-ingress-v1`, account `ea9f2e33230109fafd96caa736594600`.

- Current deployed source exposes `GET /health` and `POST /shopify/webhooks` only.
- It verifies Shopify HMAC over the raw request body using one `SHOPIFY_API_SECRET`.
- It forwards the raw body and Shopify headers to `https://n8n.henvalt.com/webhook/henvalt/ingest`.
- No signed/trusted internal app-key header or app-specific route is produced.
- Current settings: `N8N_INGEST_URL` plain-text binding; `SHOPIFY_API_KEY` plain-text binding; `SHOPIFY_API_SECRET` secret binding. Secret value was not retrieved.
- The deployed Worker was inspected read-only. No Worker source, settings, bindings, or secrets were changed.

## Exact trigger inventory (five)

| Table | Trigger | Function |
|---|---|---|
| `conversation_messages` | `conversation_message_initial_intent` | `set_initial_customer_reply_intent` |
| `delivery_attempts` | `measure_email_usage_after_attempt` | `measure_email_usage_after_attempt` |
| `delivery_requests` | `enforce_billing_entitlement_before_delivery` | `enforce_billing_entitlement_before_delivery` |
| `messages` | `messages_append_sender_identity_footer` | `messages_append_sender_identity_footer` |
| `recovery_interventions` | `trg_stamp_recovery_intervention_delivery_times` | `stamp_recovery_intervention_delivery_times` |

## Decisions required before any production migration

1. Introduce stable internal app keys (for example `legacy` and `public_v1`) distinct from Shopify client IDs. Store secret references only in a private server-side registry.
2. Carry app key through OAuth state, Shopify connection, token refresh, Worker ingress, n8n HMAC verification, privacy request and audit records. Never infer app identity from an unsigned shop header.
3. Bind every Shopify-originated operational row to an exact `shopify_connection_id` (nullable during staged backfill only), including webhook receipt, canonical event, customer, checkout, opportunity, recovery, intervention, delivery, order, attribution and revenue.
4. Make all relevant uniqueness/idempotency keys connection-aware after collision review. Preserve global shop-domain uniqueness. Do not backfill missing/conflicting rows by guessing.
5. Replace one-shop dashboard assumptions with a server-verified store selector. One connection may auto-select; multiple connections require explicit selection. Every read/write must verify membership and selected connection belongs to the tenant.
6. Scope privacy export/redaction to the exact shop connection. Never execute tenant-wide deletion from a shop-level redaction request when the tenant can own multiple stores. Retain unresolved requests durably for unlinked/uninstalled shops.
7. Decide whether email unsubscribe/suppression is per-store or tenant-wide. Preserve explicit lineage and avoid silently changing current consent semantics.
8. Decide billing principal (tenant, per-store Shopify subscription, or hybrid) before changing `billing_accounts`, billing triggers or charge idempotency.
9. Continue auditing every RPC, SQL function, view, trigger, and external caller before drafting a review-only migration.

## Safety boundary

This document is an audit record, not implementation or approval to apply changes. No Supabase DDL/data, Edge Function deployment, n8n workflow, Cloudflare Worker, Shopify app configuration, production credential, or live merchant setting was changed.
