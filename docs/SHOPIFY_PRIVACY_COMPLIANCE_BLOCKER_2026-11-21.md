# Shopify App Store privacy-compliance blocker — 2026-11-21

**Decision: NO-GO for public App Store distribution until all three mandatory compliance topics are configured and the receiving path is proven end to end.** This is a candidate-branch audit only. No production app configuration, webhook subscription, Worker, Edge Function, database or workflow was changed.

## Shopify requirement

Shopify requires every App Store-distributed app to subscribe to all three compliance topics, even if it does not store customer personal data:

- `customers/data_request` — provide the requested customer data to the merchant.
- `customers/redact` — erase/anonymize the requested customer's personal data.
- `shop/redact` — erase the shop's data after uninstall.

Shopify requires these subscriptions to be declared in the app configuration TOML using `compliance_topics`; they are not part of the ordinary per-shop GraphQL `webhookSubscriptionCreate` loop. See:
- https://shopify.dev/docs/apps/build/compliance/privacy-law-compliance
- https://shopify.dev/docs/api/webhooks/2026-10
- https://shopify.dev/docs/apps/build/security/app-security-checks/missing-compliance-webhooks

## Current HENVALT evidence

### App configuration

The current `shopify.app.toml` contains a webhook API version but no `[[webhooks.subscriptions]]` entry with `compliance_topics`. The OAuth code's immutable operational webhook list contains 12 business topics and no compliance topics. This is not a substitute for the TOML compliance declaration.

### Receiving path

The current Cloudflare ingress accepts any signed Shopify topic and forwards it to the active `HENVALT_INGEST` endpoint. The active ingest graph and its sanitized candidate fixture have no dedicated compliance-request branch. A valid HMAC and HTTP 200 from the generic ingress do not prove a privacy request was durably handled.

### Database

Read-only production catalog inspection found `henvalt.shopify_privacy_requests` with 0 rows and the following relevant capabilities:
- Service role can insert, select and update the queue; client roles have no direct grants and the table has no RLS policies.
- `henvalt.redact_shopify_customer_data(uuid,text,text)` exists and is service-role-only. It performs tenant-scoped customer data deletion/anonymization, but does not itself enqueue or claim a Shopify privacy request.
- `henvalt.redact_shopify_shop_data(uuid)` exists and is service-role-only. It consumes a queued `shop/redact` request and deletes the tenant after sanitizing the queue receipt.
- `henvalt.purge_expired_shopify_privacy_exports()` exists.
- The inspected function catalog contains no `customers/data_request` export/response handler and no dedicated durable privacy webhook enqueue/worker entry point.

The presence of a queue table and isolated redaction functions is not evidence that Shopify's incoming compliance webhooks are accepted, acknowledged, completed or retried correctly.

## Required implementation before adding the TOML subscriptions

1. Create a dedicated privacy webhook ingress/handler path, or a rigorously separated branch at the shared ingress. Verify Shopify HMAC over exact raw bytes and bind the request to the shop/tenant without trusting payload tenant IDs.
2. Durably enqueue each compliance request idempotently by Shopify delivery ID before returning 2xx. Unknown shops, malformed payloads, database failure and duplicate deliveries need explicit outcomes.
3. Implement `customers/data_request`: assemble the requested customer/order data from all HENVALT stores and return it to the merchant through a controlled, auditable export process. The Shopify webhook itself is not the export response.
4. Implement `customers/redact`: call the tenant-scoped redaction function using verified shop/customer identity; handle absent customer rows and email-only payloads safely; preserve legally required records only under an approved retention basis.
5. Implement `shop/redact`: wait for Shopify's scheduled delivery, validate the queued shop identity, stop future processing/sending, delete or anonymize the tenant's data, and verify the operation. Define how backups, provider logs and n8n execution data are handled.
6. Add a lease-bound worker with retries, terminal/dead-letter states, append-only audit evidence, strict tenant isolation and no raw payload leakage to n8n execution history.
7. Test duplicates, invalid HMAC, unknown shops, service/database outage, partial failure, retry, customer-id-only and email-only payloads, completed replay, legal-hold exceptions, and full shop deletion in isolated staging.
8. Only after the endpoint and handler tests pass, add the three `compliance_topics` in `shopify.app.toml` and validate the actual Shopify app configuration. Do not add a configuration-only declaration that points at an unimplemented handler.

## Explicit release gate

- [ ] All three compliance topics declared in Shopify app configuration.
- [ ] The configured URI resolves to the intended production endpoint with valid TLS.
- [ ] Each topic reaches a dedicated handler and is durably accepted before 2xx.
- [ ] Customer data request export is implemented and tested.
- [ ] Customer redaction is implemented and tested.
- [ ] Shop redaction is implemented and tested, including tenant-wide stop and deletion.
- [ ] Retry, idempotency, audit, backup and execution-retention behavior is documented.
- [ ] Isolated end-to-end acceptance evidence exists.
- [ ] Shopify app configuration validation and App Store security checks pass.

**Current status: NOT IMPLEMENTED / NOT CONFIGURED / NO-GO.** Keep the current app configuration unchanged until the complete handler exists.
