# V2 recipient resolution and delivery authorization contract

Status: design and implementation gate only. No production endpoint, migration, n8n workflow or provider behavior is changed by this document.

## Why the existing delivery endpoint is not a V2 adapter

The deployed `henvalt-mailersend-delivery` function accepts `tenant_id`, `delivery_request_id`, recipient `to`, sender, subject and body from its caller. It retrieves a tenant MailerSend credential through the legacy `get_mailersend_token_for_delivery` RPC and relies on the legacy tenant-scoped `authorize_delivery_request` flow. That contract cannot prove the recipient, checkout, consent, suppression, app and connection all belong to one immutable Shopify installation.

Do not send V2 work through this endpoint. Do not pass customer email addresses, Shopify tokens, or raw Shopify payloads into n8n.

## Required V2 shape

1. The V2 opportunity is tied by composite foreign keys to one tenant, app, connection, checkout, candidate and verified receipt.
2. A server-side contact resolver uses the exact connection's stored Shopify token reference and Admin GraphQL API to fetch only the customer email field required for delivery. It must verify the customer GID belongs to the exact checkout's customer identity and handle redacted/absent email as unavailable.
3. The recipient email remains transient in a trusted server-side Edge Function. It is never returned to the browser, n8n, logs, database rows, provider tags, error text or analytics.
4. The merchant's sender profile and MailerSend credential are resolved server-side for the same merchant billing principal. Sender identity must be verified and active.
5. An atomic, single-use authorization RPC rechecks:
   - exact app/connection/tenant active and not uninstalled;
   - checkout still OPEN and no same-store order conversion;
   - current exact-store consent is timestamped SUBSCRIBED;
   - jurisdiction country/state has a known, supported policy decision;
   - no exact-store unsubscribe, complaint, hard bounce or merchant suppression;
   - recovery is enabled and merchant has not paused the flow;
   - sender is verified, provider credential is present and provider usage cap has room;
   - opportunity/intervention is due and has not already been sent or claimed.
6. The authorization claim creates a unique send attempt and a short-lived, one-time send permit. Retries must reuse the same idempotency key and cannot create a second provider submission after an ambiguous provider response.
7. The Edge Function resolves the permit, performs the Shopify customer lookup and MailerSend submission, then stores provider message ID/status and only the minimum necessary delivery metadata. No email is returned to n8n.
8. n8n receives only opaque opportunity/intervention/permit identifiers and non-PII statuses. It can schedule and coordinate work but cannot bypass the authorization RPC.
9. Provider webhooks map message ID to the exact send attempt, connection and tenant; bounce/complaint/unsubscribe events create store-scoped suppression and invalidate unused permits.
10. A Shopify order, consent withdrawal, merchant pause, uninstall, provider suppression or billing-cap exhaustion invalidates pending permits before provider submission.

## Required state machine

`CONTACT_RESOLUTION_PENDING → CONSENT_AND_JURISDICTION_CHECK → READY_FOR_AUTHORIZATION → AUTHORIZED_ONCE → PROVIDER_SUBMITTED → DELIVERED | BOUNCED | COMPLAINED | FAILED | AMBIGUOUS`

No direct transition from opportunity creation to provider submission is allowed. Ambiguous provider outcomes must be reconciled by provider message/idempotency evidence before retry.

## Protected customer data launch blocker

The existing Shopify app config requests `read_customers`, but a public app that retrieves customer email is Level 2 protected customer data. Shopify requires public apps to request protected customer data access and the specific email field, meet Level 1 and Level 2 requirements, and participate in data-protection review. Development stores can be used for development after selecting the relevant data/fields, but that is not production approval.

This means email retrieval must be designed to tolerate redacted or unavailable fields. HENVALT must not assume the presence of an email just because a scope is in the TOML or OAuth token.

## Initial product safety policy

- Start with email only.
- Require explicit, current SUBSCRIBED email marketing consent for the first public version, even where a jurisdiction might permit other bases for some abandoned-cart messages.
- If country/state or policy version is unknown, do not send.
- Do not infer consent from Shopify pixel analytics consent, checkout completion, customer account existence, or email presence.
- Customer reply automation is not part of the first release; inbound replies become human-reviewed events.
- Do not bill until exact-store order attribution is confirmed and the revenue ledger is posted.

## Acceptance tests required before V2 can send

- Same customer identifier in two stores yields two separate contact lookups and permits.
- Store A route token cannot resolve Store B's access token, email, suppression, consent, or sender.
- Missing/blank/redacted email returns no-contact and creates no provider request.
- Unsubscribed, pending, invalid, redacted, unknown, stale, or timestamp-conflicting consent blocks the send.
- Unknown country/state and unsupported policy version block the send.
- Store A unsubscribe/complaint/hard bounce does not suppress Store B by accidental tenant-wide join; Store B remains independently eligible if all its own checks pass.
- A same-store order arriving between authorization and provider submission invalidates the permit.
- Two concurrent claims for the same intervention produce at most one valid permit.
- A consumed/expired/revoked permit cannot be reused.
- Provider timeout after submission is ambiguous, not blindly retried.
- Uninstall or merchant pause prevents every unsubmitted send.
- Logs and n8n execution records contain no recipient email, Shopify access token, route token, raw body or provider API key.

## Current verified boundary

The existing production MailerSend Edge Function is legacy and tenant-scoped. The new consent and checkout-country projectors are branch-only candidates. No V2 recipient resolver, send permit, suppression engine, provider proxy or n8n adapter has been deployed or connected.
