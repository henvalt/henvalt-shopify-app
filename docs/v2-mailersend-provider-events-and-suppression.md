# MailerSend V2 provider events and exact-store suppression

Status: branch-only candidate. Migration 016 and the Edge Function are not deployed. No MailerSend account webhook was created or modified.

## Time-sensitive provider compatibility

MailerSend documents that webhook version 1 stops working on **1 December 2026**. Version 2 uses the `Signature` header and HMAC-SHA256 over the exact raw request body, compared as a hex digest. MailerSend retries non-2xx deliveries with exponential backoff for up to roughly three days. HENVALT must use version 2 for any new provider webhook and verify the raw body before parsing or processing it.

## What this candidate adds

- Server-only provider registry per merchant tenant, holding MailerSend domain ID and Vault secret references for the webhook signing key and a separate recipient-fingerprint key.
- Exact-store intervention and send-attempt lineage, including provider account, immutable Shopify connection and customer identity.
- Minimal idempotent provider event inbox keyed by provider account + event ID, with raw-body SHA-256 digest and provider message IDs.
- Exact-store suppression rows for unsubscribe, spam complaint and hard bounce, linked to the send attempt and customer identity.
- Recipient address is converted to keyed HMAC-SHA256 fingerprint in memory; plaintext email is never stored in provider events or suppression rows.
- Events that arrive before their send attempt has a provider message ID remain UNMATCHED. A same-body retry may complete correlation later; a changed body reusing the event ID is rejected.
- The Edge Function accepts MailerSend's `Signature` header, forwards raw bytes to the Vault-backed RPC, and returns only a safe status. It does not log or echo payloads.

## Suppression policy

- `activity.unsubscribed` → permanent exact-store UNSUBSCRIBED suppression.
- `activity.spam_complaint` → permanent exact-store SPAM_COMPLAINT suppression.
- `activity.hard_bounced` → permanent exact-store HARD_BOUNCE suppression.
- `activity.soft_bounced` is recorded on the send attempt but is not treated as permanent suppression by this first policy.
- Delivered events update delivery state but do not prove a recovered order.
- Events with no matching provider message ID are retained as UNMATCHED and cannot mutate any store's suppression state.
- Suppression in Store B must not affect Store A, even when both stores share a tenant and Shopify customer reference.

## Pixel attempt outcome reconciliation

Migration 039 adds a separate pixel-attempt correlation path to the same signed provider inbox. The webhook Edge Function first verifies and ingests the exact raw-body signature through the existing Vault-backed RPC, then asks a service-only reconciliation RPC to correlate the already-verified event ID. The caller never supplies a provider message ID to the reconciliation RPC.

- Provider activity events can correlate through the stored provider message reference on a pixel attempt.
- An ambiguous pixel attempt becomes SUBMITTED only when a signed MailerSend activity event matches its provider account and message reference.
- The transition settles the reserved provider cost; it does not mark the recovery as revenue recovered.
- Event-to-pixel-attempt lineage is stored separately from legacy checkout send-attempt lineage.
- Replays are idempotent. Events without a matching message reference remain unmatched and cannot authorize a resend; the webhook returns a retryable 503 while correlation is pending, allowing MailerSend's signed-event retry schedule to deliver the same event again.
- If the provider accepted a message but neither the response nor a later webhook exposes a correlatable message ID, the attempt remains AMBIGUOUS and its cost remains RESERVED for manual reconciliation. There is no automatic resend.

## Critical implementation boundary

The provider registry requires two separately provisioned Vault secrets: MailerSend webhook signing secret and recipient-fingerprint key. The candidate does not seed either secret or configure MailerSend. It does not create interventions from opportunities or authorize sends. During setup, the provider registry may remain PENDING while MailerSend performs its URL-validation ping; the documented fixed test secret is accepted only for `webhook.test`, and that ping is not persisted. Real provider events require ACTIVE status and the account-specific Vault signing secret. The existing deployed MailerSend sender function remains legacy and is not safe for V2 because it accepts caller-supplied recipient email and uses tenant-scoped authorization.

## Acceptance tests

- Valid raw-body signature accepted; invalid signature rejected.
- Wrong MailerSend domain rejected.
- Duplicate event ID/body is idempotent; same ID/different body rejected.
- A provider event that arrives before message-ID correlation can be retried and resolved later.
- Unsubscribe, complaint and hard bounce map only through a known send attempt to one exact store.
- Same customer identifier in Store A and Store B produces independent suppression rows.
- Recipient email and raw webhook payload are not stored.
- Service-role only RPC; no browser role can call it.

## Next connected work

1. Implement V2 contact resolver with Shopify protected-customer-data approval handling.
2. Implement atomic single-use delivery permit that checks exact-store consent, jurisdiction, suppression, checkout/order, app/store, sender and billing entitlement.
3. Wire the V2 provider proxy to resolve the recipient server-side and submit to MailerSend; do not expose the recipient to n8n.
4. Add provider account setup and webhook V2 creation only after the merchant explicitly configures the provider.
5. Add full provider retry/ambiguous-send reconciliation and refund-aware attribution.
