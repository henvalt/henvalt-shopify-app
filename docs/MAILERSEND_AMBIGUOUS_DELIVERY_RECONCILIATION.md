# MailerSend ambiguous-delivery reconciliation — candidate specification

Status: design and contract only. No provider token was read, no MailerSend API request was made, and no production workflow or database object was changed.

## Problem

The delivery Edge Function calls `POST /v1/email`. A successful response is `202 Accepted` and includes `x-message-id`. The current handler returns that header to n8n. If the connection fails after MailerSend accepted the request, HENVALT cannot infer rejection from the transport error. The quota reservation must remain held.

The current quota candidate correctly:
- reserves quota in the same transaction as the delivery claim;
- consumes on `ACCEPTED`, `DELIVERED`, or `UNKNOWN`;
- releases only a narrow allowlist of explicit 4xx provider rejections;
- leaves 408, 409, 429, 5xx, missing status and transport ambiguity held;
- upgrades a previously RELEASED reservation to CONSUMED if later acceptance evidence arrives;
- retains append-only transition events and does not expire unresolved holds.

## Provider lookup capability

MailerSend documents a searchable sending-log API:
- `GET /v1/emails` requires `domain_id`, `date_from`, and `date_to`; supports filtering by recipient, subject, tag, status and interaction; and returns one row per recipient email.
- The list result includes `message_id`, `status`, `tags`, `recipient`, `created_at`, and `domain_id`; documented email statuses are `queued`, `sent`, `rejected`, and `delivered`.
- `GET /v1/email/{email_id}` returns the individual email record and its activity.
- The list endpoint requires a token with `activity_read` or `activity_full`; the single-email endpoint accepts `email_full`, `activity_read`, or `activity_full`.
- The list endpoint allows up to 1,000 rows per page and 100 pages, and is rate-limited to 10 requests/minute shared with the activity endpoint. It supports exact tag and message-ID filtering. Split large date ranges into bounded windows; hitting a page or rate limit before exhausting the window makes a negative result inconclusive.
- The live provider configuration has a `verified_domain` name but no typed domain ID. MailerSend's `GET /v1/domains` can map a verified domain name to its provider domain ID, but requires the separate `domains_read` permission; do not assume `activity_read` includes it.
- Results are retained only for the account's configured activity-retention period. A no-match result is therefore not proof of non-acceptance unless the complete query window is known to be retained and fully paginated.

Official API references:
- https://developers.mailersend.com/api/v1/email/emails
- https://developers.mailersend.com/api/v1/email/activity
- https://developers.mailersend.com/api/v1/email

## Correlation contract

Every HENVALT provider request already includes these tags:
- `tenant:<tenant UUID>`
- `delivery:<delivery request UUID>`
- optional intervention and correlation IDs

A reconciliation worker must use the exact tenant + delivery tags and the persisted attempt time window. It must not query solely by recipient, subject, or amount. The returned record must also match the expected sender, recipient, domain, and a bounded created-at interval. Persist only provider IDs, status, timestamps, and a minimal evidence digest; do not copy message content or recipient PII into audit payloads.

The current schema must be audited before implementation to confirm it durably stores:
- `x-message-id` when the provider returns 202;
- provider domain ID and the provider request/attempt timestamp;
- the exact delivery tags sent;
- provider response status and whether the response body was complete.

If any of those are absent, reconciliation must remain unavailable rather than inventing correlation data.

## Decision table

| Provider evidence | Reservation outcome |
|---|---|
| Exactly one matching email record, status `queued`, `sent`, or `delivered` | Consume; record the provider message/email ID and evidence |
| Exactly one matching record, status `rejected` | Consume. The API created an email record; rejection is a later delivery outcome, not proof the send request was never accepted |
| More than one matching record | Consume and raise a duplicate-send incident; preserve every matching provider ID and require operator review; never choose an arbitrary row |
| No match, incomplete pagination, rate limit, API error, expired retention, or inconclusive time window | Keep RESERVED; no retry and no release |
| Exact message ID returned by original 202 response and a successful provider lookup | Consume; message ID is primary correlation |
| A late webhook or lookup reports acceptance after an earlier release | Re-consume and append an explicit late-acceptance event; preserve the earlier release event |

A provider lookup can prove that a message exists. A negative search is materially weaker: it cannot prove that a timed-out POST was never accepted unless retention, domain scope, date bounds, filters and pagination are all demonstrably complete.

## Operator controls

A future operator action must:
1. require an authenticated OWNER/ADMIN session and derive tenant/shop/provider configuration server-side;
2. record the authenticated actor ID, reason, exact reservation ID and evidence reference;
3. permit only evidence-backed transitions;
4. reject arbitrary browser-supplied provider status, provider IDs, tenant IDs or evidence;
5. serialize with late provider callbacks and reservation transitions;
6. be idempotent and append-only;
7. never release an ambiguous reservation merely because it is old;
8. expose an unresolved state and alert/queue ownership rather than silently clearing it.

No operator RPC should be added until the MailerSend token's actual read scopes and retention settings are confirmed. No scope upgrade or paid plan is assumed.

## Required tests before implementation

- exact message ID match; exact tag match; sender/recipient/domain mismatch;
- zero, one, and multiple matching records;
- pagination complete vs interrupted and page-limit exhaustion;
- date-window boundaries and provider retention expiry;
- 401/403 scope denial, 404 domain mismatch, 422 invalid query, 429 rate limit, 5xx and transport timeout;
- late acceptance racing an operator action;
- two reconcilers racing the same reservation;
- release followed by late accepted webhook;
- evidence redaction and RLS/service-role boundaries;
- no-match never releases unless complete retention-backed negative evidence is available.

## Release boundary

This document is not authorization to grant MailerSend scopes, change account settings, send email, create a provider lookup job, release reservations, deploy a function, or activate recovery/delivery. Keep ambiguous reservations held until the complete provider-evidence path has passed isolated staging acceptance.

## Live schema audit — read-only, 2026-11-23

The connected Supabase project was inspected using catalog metadata and the definition of `henvalt.record_delivery_result`; no rows or database objects were changed.

Confirmed:
- `henvalt.delivery_attempts` persists `tenant_id`, `delivery_request_id`, `provider`, `provider_message_id`, `provider_status_code`, `state`, `retryable`, `provider_response`, and `attempted_at`.
- `record_delivery_result` writes the supplied provider message ID and response JSON to the attempt row, and preserves a non-null provider message ID on the delivery request.
- `henvalt.provider_configs` has a JSONB `configuration`; `henvalt.sending_identities` has JSONB `metadata`. Neither table exposes a dedicated typed `domain_id` column in the inspected schema.

Consequences:
- Successful 202 responses already have a durable message ID path; the handler forwards `x-message-id` and the n8n classifier records it.
- The ambiguous transport case has no message ID by definition. Tag-based search is therefore required, and the exact MailerSend sending-domain ID must be resolved from verified server-side configuration or a separately authorized provider-domain lookup.
- The presence of JSONB configuration fields does not prove a usable domain ID or a MailerSend read scope. Do not infer either from the schema alone.
