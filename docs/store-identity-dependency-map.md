# HENVALT store-identity dependency and deletion map

**Status:** read-only Supabase catalog and function-definition audit. No production objects or data changed.

## 1. Authoritative identity anchor

The existing `shopify_connections` row is the correct durable store identity anchor. `shop_domain` is globally unique today, and the connection belongs to a tenant. `pixel_keys` already references this row directly with a non-null `shopify_connection_id` FK and cascades when a connection is deleted.

The rest of the Shopify-originated business graph is still largely tenant-bound. The migration must add a connection binding without weakening tenant authorization. At every relationship boundary, validate both tenant and connection identity.

## 2. Dependency graph and required lineage

| Stage | Existing direct parent links | Required store binding |
|---|---|---|
| Shopify connection | tenant | app identity + connection |
| Webhook receipt | tenant; source/idempotency keys | connection + app identity |
| Canonical event | tenant; optional webhook receipt | connection, inherited from verified receipt |
| Customer | tenant; Shopify customer ID | connection + Shopify customer ID |
| Checkout | tenant; optional customer | connection + customer on same connection |
| Opportunity | tenant; event/customer/checkout | connection + all parents same connection |
| Recovery sequence | tenant; opportunity | connection inherited from opportunity |
| Intervention | tenant; sequence/opportunity | same connection as opportunity |
| Delivery request | tenant; intervention/opportunity/recovery | same connection, rechecked before send |
| Delivery attempt | tenant; delivery request | inherit connection through delivery request |
| Order | tenant; optional customer/checkout | connection + Shopify order ID |
| Attribution | tenant; order/opportunity/recovery/intervention | same connection across all matched lineage |
| Revenue ledger | tenant; order/attribution/opportunity/recovery | same connection as order and attribution |
| Billing measurement | tenant; billing period/ledger entry | depends on selected billing principal; store FK when per-store billing |
| Billing usage charge | tenant; measurement | same billing principal as measurement |
| Conversation | tenant; customer/delivery/opportunity/recovery/intervention | inherit exact originating delivery connection |
| Conversation message | tenant + composite conversation FK; provider event | inherit conversation connection |
| Email usage measurement | tenant; delivery attempt | derive exact store through delivery attempt |
| Unsubscribe token | tenant/customer; unique token hash | bind to originating connection through customer/intervention lineage |
| Email suppression | tenant/customer/email | explicit store-scoped vs tenant-wide suppression policy |
| Privacy request | optional tenant; shop domain/shop ID/webhook ID | app key + exact connection when resolved; retain unresolved receipt |

## 3. Foreign-key delete semantics that matter

The deployed catalog confirms:
- Customer deletion cascades to customer conversations and unsubscribe tokens.
- Conversation deletion cascades to conversation messages through the composite `(tenant_id, conversation_id)` FK.
- Delivery request deletion cascades to delivery attempts and customer conversations.
- Opportunity deletion cascades to recovery sequences and recovery interventions; delivery requests can retain nullable opportunity/recovery references because those FKs use `SET NULL`.
- Order deletion cascades to order attribution; revenue ledger order references are `SET NULL`.
- Tenant deletion cascades through most operational records, including customers, checkouts, opportunities, recovery, delivery, billing and ledger records.
- Shopify connection deletion cascades to pixel keys.
- Privacy request tenant FK is `ON DELETE SET NULL`, which allows a compliance receipt to survive tenant deletion.
- Email usage measurement has a restrictive FK to delivery attempts, so delivery-attempt deletion can be blocked until the usage record is handled.

**Design warning:** the current `redact_shopify_shop_data` deliberately detaches the privacy receipt and deletes the entire tenant. Because one tenant can have multiple active Shopify connections, this is not a safe multi-store shop-redaction policy without a product/legal decision that the tenant is exactly one Shopify shop. A future store-level deletion must remove/anonymize only the selected connection's data and preserve shared tenant data and other stores.

## 4. Privacy request receipt schema gap

Live `shopify_privacy_requests` columns include:
- `tenant_id` (nullable)
- `shop_domain` (required)
- `shopify_shop_id` (nullable)
- `topic`, `webhook_id`, `customer_id`, `request_id`
- raw `payload`, processing status/timestamps/errors
- expiring `result_payload`

There is no `app_key` and no `shopify_connection_id`. The existing unique webhook ID supports idempotency, and the nullable tenant FK preserves unresolved requests. The additive contract should preserve those properties while adding app identity and a nullable exact connection reference. Historical/uninstalled connection resolution must be possible without trusting a current active connection alone.

## 5. Writer and reader contracts requiring coordinated versioning

### Ingress and identity
- `verify_shopify_webhook_hmac`: current signature has no app key; must resolve app-specific secret from trusted route/app identity.
- `resolve_shopify_tenant`: returns tenant only; add a connection resolver returning tenant + connection + app identity.
- `upsert_canonical_event`, `resolve_identity`, `upsert_customer`, `upsert_checkout`, `create_opportunity_idempotent`: connection-aware variants required; metadata shop domain cannot be the sole authority.

### Recovery and delivery
- `get_abandoned_cart_candidates`, `get_abandoned_checkout_candidates`, `get_browse_abandonment_candidates`: return exact connection ID.
- Corresponding `process_*_candidates`, `get_recovery_worker_context`, intervention and delivery request creation: preserve and validate exact connection.
- `authorize_delivery_request`: independently verify every linked row has the same tenant + connection and connection remains active at send time.
- `stop_recovery_after_order`, order projection, attribution and ledger posting: scope conversion-stop and attribution to the same store, not tenant alone.

### Consent, unsubscribe and replies
- `apply_shopify_email_consent_update`, `suppress_customer_recovery`, `create_unsubscribe_token`, `unsubscribe_customer_by_token`: bind to exact customer/store identity and define whether an explicit unsubscribe is store-only or tenant-wide.
- `process_mailersend_inbound_reply`, `get_mailersend_reply_to_for_delivery`: inherit the exact store from conversation → delivery request → intervention/opportunity/recovery; do not route by sender email alone.
- `evaluate_communication_eligibility`: accept or derive a connection-scoped customer identity and consent evidence.

### Privacy and dashboard
- `export_shopify_customer_data`, `redact_shopify_customer_data`: require exact connection; do not match every customer in tenant by email.
- `redact_shopify_shop_data`: replace tenant deletion with a store-level compliance action after explicit shared-tenant policy.
- Dashboard, revenue series, billing summary and billing claim RPCs: store-addressed requests must aggregate only the selected connection. Tenant-wide reporting must be explicit.

## 6. Billing principal is still a product decision

Current `billing_accounts` primary key is `tenant_id`; billing periods, measurements and usage charges are tenant-bound. The live trigger `enforce_billing_entitlement_before_delivery` enforces tenant-level caps. This is consistent with one subscription per tenant, not one subscription per Shopify app installation.

Before changing billing schema, select one:
- **Tenant billing:** one external billing customer for the merchant organization; stores roll up to a tenant account, and per-store analytics are separate from charge aggregation.
- **Store billing:** each Shopify connection has its own subscription and cap; billing account/period/measurement/charge keys must include connection ID.
- **Hybrid:** provider determines billing principal, represented explicitly rather than by nullable magic fields.

Do not infer this from the existing Shopify billing tables or silently migrate tenant subscriptions into store subscriptions.

## 7. Migration sequencing and compatibility

1. Freeze current production shape as baseline; preserve existing app and all current credentials.
2. Add app registry and connection app identity; keep secrets in Vault references only.
3. Add nullable connection IDs to receipt/source and core business tables. Add indexes concurrently where appropriate after review.
4. Introduce connection-aware RPC versions and update all callers as one compatibility rollout.
5. Backfill only when explicit immutable source lineage resolves exactly one connection in the same tenant.
6. Quarantine missing, ambiguous, mismatched and cross-store-collision rows. Do not auto-select the only active connection.
7. Add composite uniqueness and FKs only after collision report and parent lineage validation.
8. Migrate privacy, consent, suppression, replies, dashboard and billing according to their explicit scopes.
9. Switch read paths only after writer coverage and reconciliation pass.
10. Retain rollback path: old columns/RPC signatures and legacy app credential path remain available until cutover criteria pass.

## 8. Remaining blockers before executable DDL

- Full list of every external Edge Function, n8n, Worker and app-side RPC caller is not yet reconciled.
- Some RPC definitions and dynamic SQL need a complete caller-by-caller review.
- Billing principal and unsubscribe/suppression policy require explicit product decisions.
- Store-level privacy semantics and historical connection retention require review.
- Existing source rows without trusted store markers must be quantified per table before any backfill.
- Additive migration and rollback SQL still need independent static validation; the current preflight SQL remains SELECT-only and must not be applied.

## Safety

Review document only. No migration was applied, no production function or table changed, and no workflow or deployment was touched.
