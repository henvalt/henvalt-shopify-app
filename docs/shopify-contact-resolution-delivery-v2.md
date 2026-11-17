# V2 trusted contact resolution and MailerSend delivery

Status: candidate migration 018 and Edge Function are branch-only. Not applied or deployed. No secrets have been seeded.

## Security boundary

- Only an internal caller holding the dedicated HENVALT_DELIVERY_AUTH_TOKEN can invoke the Edge Function.
- The caller supplies an intervention ID and message content, never a customer email or Shopify customer ID.
- A service-role-only SQL resolver derives the customer reference from the exact-store identity graph and reads the Shopify access token, MailerSend send-only API token, and recipient-fingerprint key from Vault.
- Shopify email is retrieved by Admin GraphQL using the exact connection's shop domain, access token, and Shopify customer ID. There is no email fallback or tenant-level customer match.
- Email stays in Edge Function memory. The function computes a keyed HMAC fingerprint and passes only that fingerprint to the permit RPC.
- Permit issue and consume re-check checkout, same-store order absence, current subscribed consent, supported jurisdiction, suppression, app/store/tenant, verified sender, provider, and non-test billing entitlement.
- Shopify expiring offline tokens use the existing serialized refresh lease. Refresh tokens are never logged.
- The Edge Function sends one recipient to MailerSend and never returns email, customer ID, access token, API token, fingerprint secret, or permit token to its caller.

## Provider submission behavior

- MailerSend's Email API returns HTTP 202 and an x-message-id when accepted asynchronously.
- Successful submission is recorded against the exact-store send attempt.
- Explicit provider rejection is recorded as FAILED.
- Network timeout or a 202 without a message ID is recorded as AMBIGUOUS and is never automatically resent.
- If MailerSend accepts but recording the message ID fails, the function returns a safe pending status; provider-event reconciliation is required.

## Configuration and launch blockers

1. Seed the provider's MailerSend send-only API token reference in Vault and api_token_secret_ref.
2. Seed/activate provider registry, signing secret and recipient fingerprint secret only after owner-controlled setup.
3. Verify a sender profile for the exact Shopify store.
4. Obtain Shopify Level 2 protected customer data approval for email access.
5. Activate a merchant billing entitlement with an agreed performance percentage and monetary cap reservation. The current live billing account remains PENDING/test-mode/0%, so it is blocked.
6. Implement monetary usage-cap reservation/reconciliation and complete end-to-end tests.

## Non-actions

No production SQL, Edge Function, Cloudflare Worker, n8n workflow, Shopify app or MailerSend account was changed. No secret values were read, created or copied. No customer email was sent.
