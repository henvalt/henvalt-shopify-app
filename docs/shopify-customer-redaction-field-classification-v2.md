# HENVALT customer redaction field classification — V2

Status: engineering design inventory only. This is not legal advice, a retention schedule, or an executable redaction policy. No production system was changed.

## Objective

Translate the exact-store V2 data graph into separate handling classes before implementing `customers/redact`. The immutable scope key is `(tenant_id, shopify_connection_id)`; the external Shopify customer reference is resolved only inside that connection. Never infer historical store lineage from a shop-domain string in metadata.

## Field classes and candidate handling

| Data class | V2 tables / fields | Candidate redaction treatment | Dependencies / caution |
|---|---|---|---|
| Direct customer identity | `shopify_customer_identity_v2.external_customer_reference` | Remove or replace with a non-reversible random tombstone only after all downstream operations are closed | The customer identity row is referenced by consent, intervention and suppression records; direct DELETE is restricted. A random replacement remains a pseudonymous row, not proof of anonymization. |
| Session and browser identifiers | `shopify_session_identity_v2.session_reference`; `shopify_session_alias_identity_v2.alias_reference` and `session_reference` | Remove aliases and scrub session references, or detach customer link where allowed | Alias rows cascade when a session row is deleted. Preserve no cross-store mapping. |
| Pixel event identifiers and payload | `shopify_pixel_event_inbox_v2.client_reference`, `customer_reference`, `checkout_reference`, `payload` | Remove customer/session/checkout references and scrub payload fields that can identify the shopper | The JSON payload is opaque and must be inspected/whitelisted at ingestion; do not assume it contains no email, URL, IP, or other identifiers. Scope by exact connection and external customer reference. |
| Checkout identity | `shopify_checkout_identity_v2.shopify_checkout_id`, `checkout_token`, `session_reference`, `customer_identity_id` | Remove checkout ID/token and session/customer links; retain only minimal non-identifying operational state if justified | Checkout tokens are sensitive identifiers. Candidate/opportunity rows depend on checkout identity; don't cascade away recovery audit accidentally. |
| Recovery activity | `shopify_checkout_recovery_candidate_v2.checkout_token`; opportunity/intervention customer links and idempotency metadata | Close/cancel future work, scrub customer/checkout references and message personalization data | Intervention → send-attempt → provider-event/cost chain is audit history. Stop future sends before scrubbing. |
| Consent evidence | `shopify_customer_email_consent_v2` and `shopify_customer_email_consent_events_v2` | Retain the minimum evidence only if an approved legal/compliance basis requires it; otherwise remove or irreversibly aggregate | Current and historical consent rows use RESTRICT FKs to customer identity. A retained consent record linked to a customer ID is still personal data. |
| Delivery authorization | `shopify_delivery_permits_v2.recipient_fingerprint`, `permit_token_sha256` | Remove expired/consumed recipient fingerprints when no longer required; expire/revoke permits | Permit rows reference interventions, attempts, provider and sender. Permit token hashes are security replay controls, not raw tokens; define retention separately. |
| Delivery and provider audit | `shopify_recovery_send_attempt_v2.provider_message_id`, `provider_email_id`; `shopify_mailer_provider_events_v2.provider_message_id`, `provider_email_id` | Keep minimal event status/timestamps only where operational or legal retention is justified; remove recipient-correlating identifiers where possible | Provider events and send attempts are referenced by suppressions, cost reservations and attribution. Preserve chain integrity without preserving unnecessary customer linkage. |
| Suppression / opt-out evidence | `shopify_delivery_suppressions_v2.customer_identity_id`, `recipient_fingerprint`, suppression type and source event/attempt | Maintain a no-send guard only if permitted and necessary; otherwise remove it under approved policy | HMAC fingerprints are pseudonymous, not automatically anonymous. Deleting suppression state may cause a prohibited future send. The current FK to customer identity is RESTRICT and source evidence is also retained. |
| Order and refund records | `shopify_order_identity_v2.shopify_order_id`, `checkout_token`, `customer_identity_id`; refund ID/amount/currency/timestamps | Separate direct customer/order identifiers from accounting facts; retain or anonymize only under an approved accounting/contractual retention schedule | Refunds reference orders; attribution references orders/checkouts/opportunities/attempts. Financial records must not be casually deleted or altered. |
| Attribution and fee ledger | `shopify_recovery_attributions_v2`, `shopify_recovery_fee_measurements_v2` | Preserve immutable amounts, currency, fee percentage, status and transaction reference if required; detach or pseudonymize customer-level links only through a controlled accounting-safe design | Fee measurements reference attribution; attribution references order, checkout, opportunity and send attempt. Refunds may reverse or credit fees. |
| Privacy request receipt | `shopify_privacy_webhook_deliveries.customer_id`, `request_id`, webhook metadata/digest | Clear customer ID only after verified processor completion; retain minimal receipt proof if policy permits | Queue completion is claim-bound. Do not mark a request complete merely because a preview or export draft exists. |
| Verified webhook audit | `shopify_webhook_deliveries` shop/topic/delivery ID/body digest/metadata | Retain only minimal integrity/audit metadata under approved schedule | Raw payload is not stored in this table; digest is not the payload. Metadata still requires review for accidental personal fields. |

## Current schema constraints that shape the implementation

- Customer identity is directly referenced by sessions, checkouts, orders and opportunities with targeted `SET NULL` behavior, but consent, consent history, interventions and suppressions use `RESTRICT`.
- Session aliases use `ON DELETE CASCADE` from sessions.
- Send attempts, permits, provider events, delivery-cost reservations, refunds, attributions and fee measurements have downstream restrictive links.
- Deleting the identity or any upstream recovery row without a staged detachment plan either fails or destroys useful audit/financial/suppression evidence.
- The recursive FK map in migration 028 exposes the actual catalog graph and deletion rules at runtime. The impact preview in migration 027 reports exact-store row counts only.

## Required redaction sequence before any executor is enabled

1. Validate the verified receipt, current queue lease, claim token, exact connection, tenant, app and shop binding.
2. Stop and cancel only the exact customer's not-yet-submitted interventions/permits; prevent new authorization while redaction is in progress.
3. Produce and persist an auditable dry-run plan with the exact-store row counts, FK map, blockers and policy version.
4. Resolve ambiguous sends first; never discard the only record of a potentially accepted provider request.
5. Apply the approved retention schedule separately to consent evidence, suppression fingerprints, provider/cost audit, and order/refund/fee accounting.
6. Scrub direct identifiers and opaque pixel/payload fields using explicit allowlists; preserve only non-identifying facts that have a documented purpose.
7. Verify that no future delivery path can resolve the customer or recipient, and that a legally required suppression control still works.
8. Record processor result and complete the privacy queue only after all checks pass.

## Explicit blockers

- No approved retention schedule or jurisdiction-specific policy.
- No approved rule for retaining/removing keyed recipient fingerprints.
- No exact-store legacy V1 row reconciliation for historical records lacking immutable connection lineage.
- No safe FK detachment design for cost reservations and provider-event audit.
- No proven pixel JSON payload allowlist / redaction contract.
- No secure export delivery workflow for `customers/data_request`.

Until these blockers are resolved, the system must continue to return `safe_to_execute=false` and keep privacy requests in review. Do not call legacy tenant-wide redaction functions.


## Send-guard implementation — migration 029

Migration 029 adds `shopify_customer_redaction_guards_v2`, keyed by the immutable tuple `(tenant_id, shopify_connection_id, customer_identity_id)`. A claim-bound `customers/redact` processor can activate the guard only while the exact-store privacy receipt has a live queue lease and matching claim-token digest.

- Permit creation and send-attempt creation pass through BEFORE INSERT guards. Each trigger takes a key-share lock on the exact customer identity; guard activation takes an UPDATE lock on that same identity row. This serializes concurrent authorization against privacy-guard activation.
- Activation and cleanup are deliberately two transactions/RPC calls. The first commits the identity lock and guard row only. A second claim-bound RPC expires unconsumed permits and cancels only interventions with no send-attempt row. This avoids a lock-order deadlock with a concurrent permit consumer that may already hold a permit row while waiting for the customer lock.
- Existing `AUTHORIZED` and `AMBIGUOUS` attempts remain untouched and are counted as unresolved. A provider request may already be in flight; it must be reconciled before any customer evidence is scrubbed.
- Suppression rows/fingerprints, provider events, cost reservations, orders, refunds, attributions and fee measurements are not modified. Both RPCs return `safe_to_complete_privacy_request=false`; no release operation is provided.
- A second active privacy receipt for a customer already guarded by another receipt is held for review rather than silently taking over the existing guard.

The migration does **not** solve in-flight HTTP race windows by itself: the delivery worker must still treat a blocked consume/authorization as final and must not send on stale context. The current V2 delivery path is fail-closed for monetary reservation and has not been production-enabled. The guard is preparation code until CI validates migration 029 and a future reviewed worker integration proves the pre-send recheck.

The SQL integration test covers same external customer reference in two stores, exact-store guard activation, permit expiry, cancellation of untouched intervention, denial of new permit and attempt inserts, and mismatched claim-token rejection. It does not claim a full concurrent provider HTTP test or a completed privacy request.

