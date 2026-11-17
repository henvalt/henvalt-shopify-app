# V2 single-use delivery authorization

Status: branch-only candidate migration 017. Not applied to live Supabase. No Edge Function, Worker, n8n workflow or provider configuration was activated.

## What this stage adds

- A V2 sender profile bound to one exact Shopify connection and one active MailerSend provider account. Legacy tenant-wide sender identities are deliberately not reused.
- A short-lived delivery permit with a three-minute lifetime. The raw random token is returned only to the trusted server caller; only its SHA-256 hash is stored.
- A keyed recipient fingerprint is stored as 32 bytes. No shopper email or raw Shopify contact payload is stored in the permit or send-attempt tables.
- Permit issuance validates the same-store app, connection, tenant, candidate, opportunity, intervention, checkout and customer identity chain.
- It requires the checkout to remain OPEN, no same-store order conversion, an explicit current SUBSCRIBED Shopify email-consent record, a known country in the initial GB/US/CA/AU policy set, no exact-store customer or recipient-fingerprint suppression, active provider, verified exact-store sender, and an active non-test billing account with an agreed non-zero performance rate.
- The monthly email count cap is evaluated at both permit issue and permit consumption using merchant-wide tenant billing scope. It is intentionally not represented as a per-store cap.
- Permit consumption rechecks critical state, creates one idempotent send attempt, marks the intervention AUTHORIZED and consumes the permit atomically. Replays, expiry, changed eligibility, or an already-claimed intervention fail closed.

## Important limits — not a send path yet

1. This migration does not call Shopify Admin API. A future trusted Edge Function must resolve the customer email using the exact connection's protected Shopify access token and customer ID, immediately before issuing the permit. The email must remain in that Edge Function's memory only.
2. This migration does not call MailerSend. A separate trusted delivery Edge Function must consume the permit and submit the message without returning recipient email to n8n or the browser.
3. The existing live billing account is PENDING/test-mode with zero performance percentage, so the current live account would fail this candidate's billing gate. This is intentional; no send is authorized until a merchant billing agreement and active entitlement are configured.
4. The usage_cap_amount is required to be positive, but provider-cost reservation/reconciliation against that monetary cap is not yet implemented. The monthly email count cap is enforced; monetary usage cap remains a launch blocker and must be reserved atomically before live sends.
5. Provider submission timeout/ambiguous outcome reconciliation is not implemented here. The provider event inbox remains the source for later delivery-state correlation, not proof of order recovery.
6. The sender profile is a new exact-store structure and has no production seed or verified sender. No existing sender was copied or reused.

## Security invariants

- No recipient email in Postgres, n8n execution data, browser responses or logs.
- No tenant-wide sender identity used as a store-specific sender.
- No send authorization from the legacy MailerSend endpoint.
- A permit can be consumed once, expires after three minutes, and is unusable if consent, checkout, order, suppression, app, store, sender, provider or billing state changes.
- Merchant-wide billing scope is explicit; the monthly email cap counts send attempts across the tenant's connected stores.
- The percentage must be non-zero and billing must be active/non-test. No percentage has been selected or written into production.

## Validation

Static contract tests and disposable PostgreSQL migration-application validation are wired into the existing identity V2 workflow. This is not production validation, and the candidate migration has not been applied to the live project.
