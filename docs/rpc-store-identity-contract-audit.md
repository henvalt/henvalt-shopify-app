# RPC Store-Identity Contract Audit

**Read-only production inspection:** 2026-11-16  
**Project:** HENVALT Supabase production project  
**No SQL, function, or workflow changes were made.**

## Key conclusion

The deployed database RPC surface is still primarily tenant-scoped or shop-domain-scoped. The important Shopify-facing RPCs do not accept an explicit `shopify_connection_id` or stable app key. This means adding columns alone would not establish store isolation: the function contracts, internal joins, idempotency keys, and every caller must be upgraded together.

All functions listed below were observed in schema `henvalt` and marked `SECURITY DEFINER` in the inspected catalog. Treat them as privileged server-side APIs: validate every argument against trusted lineage inside the function, and do not expose them as general-purpose client write APIs.

## Ingress and identity RPCs

| Function | Current deployed arguments | Missing identity |
|---|---|---|
| `verify_shopify_webhook_hmac` | `p_hmac text, p_raw_body_base64 text` | app key / selected secret identity |
| `resolve_shopify_tenant` | `p_shop_domain text` | app key and returned exact connection ID |
| `upsert_canonical_event` | tenant, webhook ID, event fields, metadata, idempotency key, correlation ID | connection FK; connection-scoped uniqueness |
| `upsert_customer` | tenant, Shopify customer ID, contact/consent fields, metadata | connection FK; customer ID is only unique within a Shopify shop |
| `upsert_checkout` | tenant, Shopify checkout ID, customer, token, value, metadata | connection FK; checkout/token uniqueness must be store-scoped |
| `create_opportunity_idempotent` | tenant, source event, customer, checkout, type, value, idempotency, correlation | explicit connection and same-connection validation |
| `apply_shopify_email_consent_update` | tenant, Shopify customer ID, email, consent, metadata | exact connection; consent source scope |

## Recovery and delivery RPCs

| Function | Current deployed arguments | Required future contract |
|---|---|---|
| `get_abandoned_cart_candidates` | inactivity, max age, limit | return exact connection; quarantine missing/ambiguous lineage |
| `get_abandoned_checkout_candidates` | inactivity, max age, limit | same |
| `get_browse_abandonment_candidates` | inactivity, max age, limit | same |
| `process_abandoned_cart_candidates` | inactivity, max age, limit | same; process only exact connection-bound rows |
| `process_abandoned_checkout_candidates` | inactivity, max age, limit | same |
| `process_browse_abandonment_candidates` | inactivity, max age, limit | same |
| `get_recovery_worker_context` | intervention ID | derive and validate connection across opportunity/customer/checkout/source event |
| `authorize_delivery_request` | tenant, delivery, intervention, recovery, opportunity, recipient, idempotency | validate one connection across all lineage and active status at send time |
| `schedule_next_recovery_intervention` | delivery request ID | derive same connection and re-check eligibility |
| `get_mailersend_reply_to_for_delivery` | tenant, delivery request | preserve tenant provider credentials but resolve store-specific sender policy |
| `process_mailersend_inbound_reply` | payload, raw body | resolve exact originating conversation/delivery/connection before state changes |

## Orders, attribution, ledger and billing

| Function | Current deployed arguments | Missing identity / decision |
|---|---|---|
| `project_order_from_event` | event ID | ensure source event and order bind to same connection |
| `evaluate_order_attribution` | order ID | enforce opportunity/order same connection |
| `stop_recovery_after_order` | attribution ID | stop only same-store recovery |
| `post_recovery_to_ledger` | attribution ID | ledger inherits validated store lineage |
| `post_recovery_to_ledger_and_measure_billing` | attribution ID | ledger lineage plus explicit billing principal |
| `process_shopify_revenue_adjustment` | event ID | exact connection and matching order |
| `reconcile_deferred_payment_webhooks` | limit | preserve exact connection when replaying |
| `measure_billing_entry` | ledger entry ID, percentage | decide tenant vs per-store billing |
| `measure_billing_period` | tenant, period, percentage | tenant-only billing model currently implied |
| `control_plane_billing_summary` | shop domain | resolve store-specific metrics and billing principal |
| `control_plane_revenue_series` | shop domain, range, granularity | verify every ledger row belongs to that exact connection |

## Privacy and unsubscribe

| Function | Current deployed arguments | Risk / required future contract |
|---|---|---|
| `export_shopify_customer_data` | tenant, Shopify customer ID, email | same Shopify customer ID may exist in multiple stores; require exact connection |
| `redact_shopify_customer_data` | tenant, Shopify customer ID, email | redact only records sourced from exact connection |
| `redact_shopify_shop_data` | privacy request ID | existing tenant-wide delete behavior is unsafe for a single shop in a multi-store tenant; replace with exact-connection deletion semantics |
| `create_unsubscribe_token` | intervention ID | token must retain exact originating delivery/connection lineage |
| `validate_unsubscribe_token` | token | return trusted suppression scope and originating store |
| `unsubscribe_customer_by_token` | token | apply explicitly chosen per-store or tenant-wide suppression policy, not accidental tenant scope |

## Control-plane OAuth and connection RPCs

Current shop-domain contracts include:

- `control_plane_shop_connection(p_shop_domain)`
- `control_plane_connect_shop(p_shop_domain)`
- `control_plane_disconnect_shop(p_shop_domain,p_webhook_event_id,p_correlation_id)`
- `control_plane_finalize_shopify_oauth_install_expiring_for_owner(p_state_hash,p_shop_domain,p_access_token,p_refresh_token,p_access_expires_in,p_refresh_expires_in,p_shopify_shop_id,p_scopes,p_user_id)`
- `control_plane_finalize_shopify_oauth_install_for_owner(p_state_hash,p_shop_domain,p_access_token,p_shopify_shop_id,p_scopes,p_user_id)`
- `claim_shopify_token_refresh(p_shop_domain,p_force)`
- `complete_shopify_token_refresh(p_shop_domain,p_access_token,p_refresh_token,p_access_expires_in,p_refresh_expires_in)`

These functions do not currently bind an OAuth state or connection to a stable app key. Token refresh claims are keyed by shop domain. A safe migration needs app-aware credentials and explicit identity persistence while retaining the existing merchant-owned app as a legacy identity.

## Required implementation order

1. Define and register app identities with stable internal keys; secret references only, never plaintext secrets in tables or source.
2. Add app key to OAuth state and connection records, with strict validation in OAuth begin/callback and refresh.
3. Introduce a trusted Worker route/secret selection boundary. Verify raw-body HMAC before forwarding and provide a server-trusted app key to downstream verification.
4. Upgrade ingress RPCs and active HENVALT_INGEST caller as one coherent contract. Resolve exact connection once and pass its ID through all Shopify-originated writes.
5. Add nullable connection references and collision diagnostics; only backfill rows with explicit, unambiguous source lineage.
6. Upgrade recovery candidate discovery, worker context, delivery authorization, conversion-stop, and ledger projection to enforce same-connection lineage.
7. Implement exact-store privacy export/redaction and decide unsubscribe scope.
8. Decide tenant/per-store/hybrid billing before changing billing tables, triggers, or idempotency.
9. Add store selector to dashboard/settings and enforce selected connection membership server-side.
10. Test legacy + future app identities, multi-store tenants, same external IDs in two stores, HMAC spoofing, uninstall, privacy, consent, unsubscribe, attribution, and billing.

## Explicit non-actions

This is a contract inventory, not a migration. No production SQL, DDL, data, RLS, grants, functions, triggers, n8n workflows, Cloudflare bindings/secrets, or Shopify app settings were changed.
