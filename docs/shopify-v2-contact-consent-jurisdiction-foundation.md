# V2 contact, consent and jurisdiction foundation

Status: branch-only candidate implementation. Migration 014 is not applied to Supabase. No live webhook, OAuth, Worker, Edge Function or n8n behavior is changed.

## What this slice establishes

- The existing app-aware OAuth candidate already registers Shopify's `customers_email_marketing_consent/update` webhook.
- The verified webhook inbox remains the sole trust boundary: the projector requires the same per-install route token, verified receipt, exact delivery ID and exact raw-body SHA-256 digest.
- Consent is keyed by `shopify_connection_id + customer_identity_id`, not tenant-wide customer identity.
- Consent evidence is append-only by exact-store webhook delivery. A separate current-state row supports fast send gating.
- The event projection stores only Shopify's customer ID reference, consent state, opt-in level, consent timestamp and source receipt. It never stores the webhook's email address or raw payload.
- Only a timestamped `SUBSCRIBED` record can become eligible for the consent portion of a later send gate. Missing timestamps become `UNKNOWN`; pending, not-subscribed, unsubscribed, invalid and redacted remain ineligible.
- Older timestamped events cannot overwrite a newer current consent state.
- Checkout identity gains an optional two-letter country code slot. Missing country stays NULL; no jurisdiction is guessed from shop location, currency, IP, browser locale or customer email.

## Important boundary

This does not yet authorize a send. Contact email must be resolved server-side from the exact Shopify installation at send time, with no email passed to n8n or logged. Jurisdiction policy must be explicit for UK, US, CA and AU and fail closed for unknown or unsupported country/state. A consent record is necessary but not sufficient: exact-store suppression, current order status, app/store/tenant status, sender verification, merchant pause and billing entitlement still need to pass in one single-use authorization.

## Next connected implementation slices

1. Extend the verified checkout projector to capture shipping/billing country code without storing address fields.
2. Add a server-only exact-store Admin API contact resolver that returns a short-lived provider-bound recipient handle, not an email address to n8n.
3. Build country/state policy registry and jurisdiction decision tests for UK, US, CA and AU; require explicit policy version and evidence.
4. Add exact-store unsubscribe, complaint and bounce suppression and provider message lineage.
5. Add atomic single-use authorization that rechecks consent, suppression, checkout/order, sender, merchant controls and usage cap immediately before MailerSend.
6. Only then create V2 interventions and connect the existing three n8n workflows to V2 work.

## Shopify reference

Shopify's `customers_email_marketing_consent/update` topic is documented as firing when a customer's email marketing consent changes. Its sample payload includes `customer_id` and `email_marketing_consent.state`, `opt_in_level`, and `consent_updated_at`. The customer email field in that sample is deliberately not persisted by this design.
