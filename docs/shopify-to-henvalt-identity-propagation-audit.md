# Shopify-to-HENVALT identity propagation audit (2026-11-16)

Status: read-only inspection of deployed Cloudflare Worker, deployed Supabase Edge Function source, and active n8n workflow definitions. This document records the current implementation, not a migration. No live configuration, secrets, database objects/data, Edge Functions, Worker code, or n8n workflows were changed.

## Executive result

The current stack has a valid legacy single-Shopify-app webhook verification path, but it does not carry a typed, immutable `app_key + shopify_connection_id` identity through the full event-to-recovery-to-delivery-to-attribution chain. The public multi-app design must therefore be treated as blocked until the coordinated identity migration is implemented and tested.

The current path has multiple checks that are useful and should be preserved:
- The deployed `henvalt-clean-ingress-v1` Worker verifies the raw Shopify webhook body with HMAC-SHA256 before forwarding.
- `HENVALT_INGEST` calls the deployed `verify_shopify_webhook_hmac` RPC again using the raw-body base64 and HMAC.
- The ingest workflow resolves the shop domain through `resolve_shopify_tenant` before binding the tenant ID used by the later ingest calls.
- `HENVALT_DELIVERY` has a header-authenticated internal webhook and calls `authorize_delivery_request` before attempting provider delivery.
- Pixel ingestion resolves a tenant from a pixel key tied to an exact `shopify_connection_id`; retain this exact-connection design.

These controls currently operate around a single global Shopify app secret and tenant-level records. They do not provide multi-app/store identity continuity.

## 1. Cloudflare ingress Worker: deployed `henvalt-clean-ingress-v1`

Retrieved deployed script content read-only from the connected Cloudflare account. The deployed Worker:
- Exposes `POST /shopify/webhooks`.
- Reads one environment binding, `SHOPIFY_API_SECRET`, and verifies the raw request body against `X-Shopify-Hmac-Sha256`.
- Validates `X-Shopify-Shop-Domain` against the `.myshopify.com` pattern and requires topic and webhook ID.
- Forwards the original raw body and Shopify headers to `N8N_INGEST_URL`.
- Has no app-key route segment, no app registry lookup, no app-specific secret selection, and no trusted connection ID added to the forwarded request.

Finding: the Worker is a legacy single-secret verifier. A future public app with a distinct Shopify client ID/secret cannot be safely introduced by merely changing the environment secret: the existing merchant-owned app must continue to verify with its own secret. The ingress contract needs an explicit, trusted app route/identity, then a server-side allow-listed secret lookup. Never select the secret based on an unsigned shop header or request body field.

## 2. Active `HENVALT_INGEST` workflow

Live active workflow ID: `VTpfGKNtu1CSQ4Rv`; 51 nodes; last updated 2026-11-13.

Observed path:
1. `Event Webhook` receives `POST /henvalt/ingest` with raw-body support.
2. `Validate & Normalize` extracts Shopify shop domain, topic, webhook/event IDs, HMAC and raw-body base64.
3. `Verify Shopify HMAC` calls `henvalt.verify_shopify_webhook_hmac` with only `p_hmac` and `p_raw_body_base64`; there is no app key or connection ID in the verification contract.
4. `Resolve Shopify Tenant` calls `resolve_shopify_tenant(p_shop_domain)`.
5. `Bind Tenant Context` takes the returned tenant ID and then sends the event to `ingest_raw_webhook_v2`.
6. The workflow later calls `upsert_canonical_event`, `resolve_identity`, `upsert_customer`, `upsert_checkout`, opportunity/eligibility/recovery RPCs, and order/attribution/ledger RPCs using tenant-scoped arguments.

Important positive: for Shopify-origin events, `Bind Tenant Context` does not use a caller-supplied tenant ID; it uses the shop-domain resolver result. This is safer than trusting a tenant ID from the body/query. However, the trusted result is a tenant ID only. No typed `shopify_connection_id` or `app_key` is attached to the event or passed through the later RPC contracts.

Specific missing identity propagation observed in workflow node contracts:
- `verify_shopify_webhook_hmac`: HMAC + raw body only.
- `resolve_shopify_tenant`: shop domain only; returns tenant mapping, not app+connection identity.
- `ingest_raw_webhook_v2`: tenant ID, source, source event ID, topic, idempotency key, payload, metadata; no connection ID/app key.
- `upsert_canonical_event`: tenant/event/customer/session/payload metadata; no typed connection ID.
- `resolve_identity`: event ID only; database function lineage audit confirms tenant-based resolution.
- `upsert_customer`, `upsert_checkout`, `create_opportunity_idempotent`: tenant-based identity and shop domain metadata, not an FK to the exact connection.
- Consent update calls `apply_shopify_email_consent_update` with tenant, Shopify customer ID, email, consent and shop domain metadata; no connection argument.
- Order projection/attribution/revenue adjustment calls pass event/order/attribution IDs but rely on tenant-scoped database lineage; prior function-body audits found no exact same-connection invariant.

The shop domain in JSON metadata is useful for diagnostics and legacy compatibility, but it is not a referential integrity guarantee and must not substitute for a typed connection FK.

## 3. Active `HENVALT_RECOVERY` workflow

Live active workflow ID: `3GEDoeCA4paXTaDF`; 46 nodes.

Observed worker path:
- Claims due jobs using `henvalt.claim_next_job(worker_id, ['execute_intervention'])`.
- Claims an intervention using `henvalt.claim_intervention_for_send(intervention_id)`.
- Loads context using `henvalt.get_recovery_worker_context(intervention_id)`.
- Preflight checks tenant active, shop connection active, intervention/recovery/opportunity state, consent, suppression, recipient, sender and schedule.
- Builds AI context and a delivery request, then calls `HENVALT_DELIVERY` as a subworkflow.

The context loader is the principal trust boundary for recovery. Prior read-only database function-body audits found it checks active shop state for some recovery types using tenant + shop-domain metadata, but it does not return and enforce a validated immutable connection ID through the full intervention/opportunity/customer/checkout/source-event lineage. The recovery workflow's delivery payload contains tenant, recovery, opportunity, intervention and message data, but no connection ID or app key.

A Shopify token-refresh node also calls `henvalt-shopify-token-refresh` with shop domain only. The deployed refresh function uses one global Shopify API key/secret and shop-domain keyed claim/fail/complete RPCs; it does not resolve app identity from a connection.

## 4. Active `HENVALT_DELIVERY` workflow

Live active workflow ID: `CvVyybGJZSnklxiZ`; 62 nodes.

Positive controls:
- The internal `POST /henvalt/delivery` webhook uses n8n header authentication.
- It validates required tenant/delivery/recovery/opportunity/intervention identifiers and email content.
- `Authorize & Context` calls `authorize_delivery_request` before the MailerSend provider call.
- Provider result is recorded through `record_delivery_result`.
- MailerSend inbound and event webhooks verify signatures through dedicated Supabase RPCs before processing.
- Unsubscribe and tracking routes use opaque tokens and explicit confirmation steps.

Identity gap:
- Delivery request input and authorization arguments include tenant, delivery request, intervention, recovery, opportunity, recipient and idempotency key, but no connection ID/app key.
- The provider call is authorized using tenant-level identity and current delivery lineage. Prior function-body audit found that `authorize_delivery_request` does not compare exact connection identity across request, intervention, recovery, sequence, opportunity, customer, checkout and source event.
- The workflow therefore cannot independently demonstrate that the source store which created an opportunity is the same store authorized to send the email.

Manual test path:
- The workflow includes a manual one-off test trigger with a fixed test delivery request UUID and fixed recipient. It calls `reauthorize_one_off_test_delivery`, requires `can_send === true` and `test_only === true`, and then calls the MailerSend delivery function. Keep this test-only gate and move the hard-coded fixture to a controlled test configuration before commercial operations; do not treat it as a production campaign path.

## 5. Deployed Supabase Edge Function caller/authentication audit

All source below was retrieved read-only from deployed versions. No secret values were read; only environment variable names and authentication logic were inspected.

| Function | Deployed version | Supabase JWT verification setting | Observed caller authentication |
|---|---:|---|---|
| `henvalt-shopify-oauth` | 27 | false | Manually validates the merchant Bearer token against `/auth/v1/user`; then uses service-role credentials internally. |
| `henvalt-control-plane` | 24 | false | Manually verifies a shared bearer token through Vault-backed `control_plane_verify_api_token`; accepts `x-henvalt-shop` after token validation and resolves the shop. |
| `henvalt-shopify-token-refresh` | 1 | true | Also manually requires the bearer token to equal the service-role key; receives shop domain and uses global Shopify app credentials. |
| `henvalt-merchant-dashboard` | 4 | false | Manually validates user token against Auth, resolves exactly one tenant membership and exactly one active store; rejects multi-store selection ambiguity. |
| `henvalt-mailersend-delivery` | 1 | true | Also manually requires service-role bearer equality; this is a server-to-server endpoint and must never be exposed to browser code. |
| `henvalt-public-mail-actions` | 4 | false | Public token-based routes; opaque tracking/unsubscribe tokens gate actions. |
| `henvalt-groq-generate` | 3 | false | Manually accepts service-role bearer or apikey equality; server-to-server only, must not be called from a browser. |
| `henvalt-pixel-ingest-proxy` | 3 | false | Validates request shape and forwards a collector shared secret to the database RPC; exact pixel-key/connection validation is performed downstream. |

Interpretation:
- `verify_jwt=false` is not automatically an authentication failure when the function performs its own authentication. The OAuth, control-plane and dashboard functions do perform manual checks.
- Functions that compare the incoming bearer/apikey to the service-role key are highly sensitive internal endpoints. Their caller must remain server-side, and the service-role credential must never appear in a browser bundle, public pixel, URL, or log.
- The current `HENVALT_INGEST` n8n Supabase credential and the internal delivery header credential are separate secret-bearing service paths. Credential values were not inspected.
- A full secret custody/rotation review remains open: confirm which n8n and Worker bindings contain service credentials, who can read them, whether they are scoped, and how rotation is coordinated. This audit does not prove the credentials are uncompromised.

## 6. Deployed OAuth and refresh identity limitations

The deployed OAuth function:
- Reads one `SHOPIFY_API_KEY` and one `SHOPIFY_API_SECRET`.
- OAuth state stores state hash, shop domain, expiry and initiating user ID; it stores no app key.
- Callback verifies Shopify callback HMAC, consumes state, exchanges the code using the single global client ID/secret and calls the legacy shop-domain finalization contract.
- The callback cannot distinguish the legacy merchant-owned app from a future public Partner-owned app.

The deployed token-refresh function:
- Reads one global Shopify API key and secret.
- Claims and persists refresh by shop domain.
- Receives shop domain from the internal n8n request, not a typed app-aware connection identity.

Both functions need app-key-aware state/connection resolution before public-app OAuth can safely coexist with the existing merchant-owned app.

## 7. Pixel identity is stronger and should be preserved

The deployed pixel collector/proxy path uses a public pixel key digest and storefront origin, then invokes `henvalt_ingest_pixel_event`. The database RPC resolves tenant through a `pixel_keys.shopify_connection_id` FK, verifies tenant ownership, and requires the connection to be active. This is a stronger store-binding pattern than the general webhook/recovery pipeline.

Required evolution:
- Keep pixel keys bound to exact connection IDs.
- Associate each connection with its trusted app key.
- Ensure pixel-created events and downstream sessions/opportunities inherit that exact connection ID.
- Continue to validate origin and consent, but do not mistake origin for the primary identity.

## 8. Required end-to-end contract

The migration must establish one authoritative identity tuple at ingress:

`app_key + shopify_connection_id + tenant_id + shop_domain`

Rules:
1. The app key is selected by a trusted route/configuration, never by an unsigned body field or arbitrary header.
2. The matching app registry entry selects the correct server-side Shopify secret; verify the original raw body before any event persistence.
3. Resolve `shop_domain + app_key` to one exact connection and its tenant. If absent, inactive, conflicting or ambiguous, reject or quarantine; never guess.
4. Attach trusted `app_key` and `shopify_connection_id` to the webhook receipt and canonical event.
5. All customer, checkout, cart/session/alias, opportunity, order, recovery sequence/intervention, delivery request/attempt, conversation/reply, tracking/unsubscribe, attribution, revenue ledger and privacy receipt records must preserve the connection lineage.
6. Before recovery eligibility, consent evaluation, delivery authorization, order attribution, conversion stop, refund/cancellation adjustment, privacy action or billing measurement, verify all related records resolve to the same connection and app.
7. Tenant-wide settings (provider config, shared sender profile, tenant billing) must be explicitly labelled and governed as tenant-wide; store-specific data and controls must be connection-scoped.
8. For legacy rows with no trustworthy connection lineage, classify as `LEGACY_SINGLE_STORE`, `AMBIGUOUS` or `UNRESOLVED`; quarantine ambiguous/unresolved records from automated sends and billable attribution.
9. Maintain legacy app compatibility by routing legacy traffic to `app_key=legacy`; add public app as a separate key and secret. Do not rotate or overwrite the legacy Shopify credentials as a shortcut.

## 9. Release gates and verification

Before any public app installation or production traffic:
- App-aware Worker route and secret registry are implemented and tested with both legacy and public app signatures.
- OAuth state, callback, token refresh, webhook ingress and uninstall all resolve the same app+connection.
- n8n ingest receives only a trusted server-derived identity, not a user-supplied tenant/connection.
- Supabase schema and RPCs persist/require connection identity end-to-end.
- Recovery worker context returns the validated connection; eligibility and delivery authorization reject cross-store lineage.
- Consent and unsubscribe behavior is store-scoped by default, with explicit merchant opt-in for tenant-wide policy.
- Order/refund/cancel attribution and billing only count same-connection, confirmed recovery; POSSIBLE/customer-only matches remain non-billable.
- Dashboard selects an authorized store and does not mix tenant-wide data into store-level charts.
- Privacy webhooks resolve exact app+connection and never delete the entire tenant for a single shop-redact request.
- Two-store and two-app regression tests pass, including same customer ID/email, reused checkout/session/cart tokens, cross-store order, unsubscribe, reply, refund, uninstall and billing cases.
- Service-role and control-plane credentials are inventoried, server-only, access-limited and rotation-tested.
- Rollout is additive, test-only first, with explicit rollback boundaries.

## 10. Evidence inventory and limitations

Read-only evidence inspected:
- Cloudflare account Worker inventory and deployed source for `henvalt-clean-ingress-v1`.
- Active n8n workflow definitions for `HENVALT_INGEST`, `HENVALT_RECOVERY` and `HENVALT_DELIVERY`.
- Deployed Supabase Edge Function sources for OAuth, control plane, token refresh, merchant dashboard, MailerSend delivery, public mail actions, Groq generation and pixel-ingest proxy.
- Earlier branch audits for PostgreSQL function-body lineage, privacy scope, tenant/store uniqueness and privileged function ACLs.

Not established by this pass:
- Secret values, secret exposure history, access logs or actual credential compromise.
- Full n8n credential ACL and service-role token rotation history.
- Every Postgres query embedded in every n8n node; the workflow audit focuses on identity-bearing boundaries and call contracts.
- Live end-to-end Shopify webhook to n8n to Supabase to email delivery on a controlled two-store test.
- Public app readiness or Shopify review approval.

No production changes were made. This audit is review-only and does not authorize merging, deploying, applying migrations, changing n8n, changing Worker code, or releasing a Shopify version.


## 11. OAuth registration confirms the active webhook route

A further read-only inspection of deployed `henvalt-shopify-oauth` version 27 confirms that the active OAuth callback registers the Shopify webhook subscriptions to the exact deployed Worker endpoint:

`https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks`

The deployed OAuth function registers and verifies 12 topics: orders/create, orders/updated, orders/paid, orders/cancelled, refunds/create, order_transactions/create, checkouts/create, checkouts/update, carts/create, carts/update, customers_email_marketing_consent/update, and app/uninstalled.

This resolves the earlier route uncertainty: the deployed OAuth code explicitly points the Shopify app's webhook subscriptions at the clean-ingress Worker, which then forwards to its configured n8n ingest URL. The alternate `henvalt-control-plane/v1/webhooks/shopify` relay exists in the deployed control-plane function, but it is not the webhook URI registered by the inspected OAuth callback.

The OAuth callback also records the verified webhook destination and per-topic subscription IDs in the tenant audit log. This is useful operational evidence, but it records a single fixed Worker destination and does not add an app key to the route or the webhook payload. The future public app must register a distinct trusted app-aware ingress route (or equivalent trusted routing mechanism) while preserving the existing legacy route and secret.

No webhook subscriptions were created, updated or deleted during this inspection.
