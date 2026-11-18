# HENVALT pixel provider submission gate V2

Date: 18 November 2026  
Status: branch-only implementation; no live function deployment or provider sends.

## Flow
1. Resolve the exact opportunity, store, customer GID, Shopify token, provider token, sender and fingerprint key through the service-only context resolver.
2. Query the exact Shopify customer by GID for email, `emailMarketingConsent`, and default-address jurisdiction evidence.
3. Persist only contact availability, country/region and consent state/timestamps. Recipient email and raw Shopify response remain transient.
4. Issue a two-minute pixel permit using a keyed recipient fingerprint and consume it once. The SQL consume function reruns the full eligibility assessment and creates the dedicated pixel send attempt and atomic merchant-wide cost reservation.
5. Query Shopify again after permit consumption. Require a valid email and current `SUBSCRIBED` state, require the keyed recipient fingerprint to match, and refresh PII-free evidence.
6. Call the final service-only SQL submission gate. It locks the attempt, permit and reservation, checks reservation state, exact fingerprint, exact-store suppression and the complete eligibility assessment.
7. Submit to MailerSend. A confirmed 202 with message reference settles the reservation; an explicit 4xx rejection marks FAILED and releases it; a transport timeout, 408, 5xx response or missing provider message reference marks AMBIGUOUS and retains the reservation. No automatic retry occurs.

## PII and credentials
The endpoint accepts only an opportunity ID and message content; callers cannot provide a recipient address or customer GID. Shopify email is not written to SQL, n8n, response payloads or logs. The provider token, Shopify token and HMAC key are resolved only inside the trusted Edge Function invocation. The public response never includes recipient email.

## Remaining race and operational boundary
A merchant/customer may revoke consent after the final Shopify lookup and before MailerSend accepts the request. The final live lookup and database gate narrow this unavoidable cross-system race but cannot make Shopify and MailerSend one atomic transaction. Webhook-driven suppression remains essential. The endpoint is not deployed, not added to n8n, and cannot send until an operator separately configures `HENVALT_PIXEL_DELIVERY_AUTH_TOKEN`, deploys the function and authorizes production activation.
