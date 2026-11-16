# Active n8n workflow store-identity audit

**Status:** read-only inspection of active workflow definitions. No workflow was executed, edited, activated, or deactivated.

## Active workflow snapshots

| Workflow | ID | Active version | Nodes |
|---|---|---|---:|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 |

## HENVALT_INGEST

Observed RPC call chain includes:
- `verify_shopify_webhook_hmac`
- `resolve_shopify_tenant`
- `ingest_raw_webhook_v2`
- `upsert_canonical_event`
- `resolve_identity`
- `upsert_customer`
- `upsert_checkout`
- `create_opportunity_idempotent`
- eligibility, sequence and intervention creation
- `project_order_from_event`
- `evaluate_order_attribution`
- `stop_recovery_after_order`
- `post_recovery_to_ledger_and_measure_billing`
- `apply_shopify_email_consent_update`
- revenue adjustment and deferred payment reconciliation

The active normalize node extracts shop domain and Shopify webhook headers. It explicitly treats shop domain as a tenant identity signal, not a trusted tenant ID. The downstream chain resolves a tenant but the existing RPC signatures audited earlier do not accept a connection ID. The current chain therefore has no durable, typed store-connection context across canonical event → customer/checkout → opportunity → order/attribution/ledger.

## HENVALT_RECOVERY

Observed DB calls include:
- candidate discovery/process RPCs for browse abandonment, abandoned cart and abandoned checkout
- job and intervention claim/lease/retry helpers
- `get_recovery_worker_context`
- tracking token creation and message rendering
- delivery request creation
- unsubscribe token creation
- Shopify token refresh discovery

The three candidate process RPCs are invoked with only inactivity, max-age and limit arguments. Candidate return signatures expose tenant/shop domain but not connection ID. Token refresh discovery selects shop domains from active connections, and the deployed refresh Edge Function then uses the one global app credential pair.

## HENVALT_DELIVERY

Observed DB calls include:
- `authorize_delivery_request`
- `record_delivery_result`
- tracking and unsubscribe token resolution
- MailerSend event processing
- `schedule_next_recovery_intervention`
- `get_mailersend_reply_to_for_delivery`
- `process_mailersend_inbound_reply`

The inbound AI context query joins conversation → customer → tenant and reads:
- `tenants.settings.store_name`
- `tenants.settings.reply_ai_enabled`
- `tenants.settings.reply_knowledge_base`

That is tenant-level configuration. There is no explicit store override or connection validation in this context query. Store branding/knowledge should be selected from the originating delivery's verified connection, with an explicit tenant-shared fallback only when configured.

## Required change design

1. Resolve `shopify_connection_id` immediately after webhook HMAC verification from the trusted app identity + shop domain.
2. Persist that ID on raw webhook receipt and canonical event.
3. Carry and validate it through customer, checkout, opportunity, recovery sequence/intervention, delivery request, order, attribution, revenue and billing measurement.
4. Candidate discovery must return the exact connection ID; delivery authorization must independently re-check that the connection is active and all linked rows belong to it.
5. Inbound reply must resolve from exact conversation/delivery lineage and verify the originating connection; never use email as the cross-store key.
6. AI context should read store-scoped settings (or explicit store override + tenant default), not silently use one tenant-wide store profile.
7. Refresh worker must request the app identity from the stored connection and use app-specific credentials.

## Current status and limits

This is a definition audit, not a successful end-to-end test. No workflow runs were started. The workflow graphs remain unchanged. The database function, caller and schema inventories still need a full reconciliation before any migration SQL is considered complete.
