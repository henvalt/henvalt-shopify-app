# Pixel delivery context resolver V2

Date: 18 November 2026  
Status: branch-only; no live Edge Function or provider send is enabled.

Migration 035 adds `resolve_shopify_pixel_delivery_context_v2(opportunity_id)`, a service-role-only, exact-opportunity resolver for the future cart/browse delivery Edge Function.

It first reruns the migration 032/033 eligibility assessment, then resolves the exact store/customer identity, active provider, verified sender profile and billing prerequisites. It decrypts only the Shopify Admin API token, MailerSend API token and recipient-fingerprint HMAC key from Vault for use by a trusted server-side caller. It returns the Shopify customer GID, exact shop domain, sender metadata and routing identifiers.

The RPC does not return a recipient email, persist recipient PII, create a permit or send attempt, reserve provider cost, enqueue n8n work, or call MailerSend. Its response explicitly reports those actions as false. The future Edge Function must fetch the customer email and current `emailMarketingConsent` from Shopify at delivery time, normalize the address in memory, compute the keyed fingerprint, issue and consume the pixel-specific permit, recheck suppression/eligibility, and submit through MailerSend without logging or persisting the email.

A fresh Shopify consent lookup narrows but cannot mathematically eliminate the race between an external consent change and an HTTP provider request. The delivery implementation must perform its final Admin API lookup immediately before submission, reject any negative/unknown state, and document this residual cross-system race. No jurisdiction policies are seeded by this migration.
