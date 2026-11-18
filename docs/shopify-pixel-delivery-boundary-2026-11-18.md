# Cart/browse delivery boundary — engineering decision record

Date: 18 November 2026  
Status: **implemented as a separate branch-only path; not production-enabled**  
Scope: PR #6 preparation branch. No production database, Edge Function, Worker, Shopify app, billing configuration, n8n workflow, or customer send was changed.

## Implemented lifecycle

Cart and browse opportunities remain distinct from checkout recovery:

- ABANDONED_CART and BROWSE_ABANDONMENT retain pixel candidate lineage.
- Pixel permit, attempt and cost-reservation tables bind tenant, Shopify connection, opportunity, pixel candidate and customer identity with composite foreign keys.
- Pixel permit issuance and consumption use separate service-only RPCs. Permits are two-minute, single-use, and store only a SHA-256 token hash.
- Permit consumption re-runs pixel eligibility and suppression checks, then creates one idempotent pixel attempt.
- The pixel attempt trigger reserves provider cost under the same tenant billing-account row lock used by checkout delivery. Both reservation ledgers count toward the monetary cap, and both attempt ledgers count toward the monthly email limit.
- A separate context resolver returns trusted Edge Function credentials and routing metadata. Recipient email is fetched transiently from the exact Shopify customer GID and is never stored in the permit, attempt, cost ledger, or n8n payload.
- The Edge Function refreshes contact, jurisdiction and Admin API marketing-consent evidence before permit issuance, then performs a second live Shopify customer lookup after permit consumption.
- A final service-only database gate rechecks current eligibility, consent evidence, suppression, attempt state and the reserved cost reservation immediately before MailerSend submission.
- Provider outcomes are recorded separately. SUBMITTED requires a provider message reference; FAILED releases the reservation; AMBIGUOUS retains it.
- A bounded stale-attempt reconciler converts old AUTHORIZED attempts to AMBIGUOUS; it never releases cost or retries automatically.

## Critical operational limits

- The jurisdiction registry has no seeded approvals. A jurisdiction remains blocked until an explicit, reviewed policy row exists.
- Shopify protected customer data access and production scopes/approval remain external launch prerequisites.
- Provider credentials, sender verification, active non-test billing, positive performance fee, usage cap and monthly email limit must be configured by the account owner.
- The final database gate narrows but cannot eliminate the cross-system race between the final Shopify consent lookup and provider acceptance.
- A provider timeout or uncertain post-request failure must remain AMBIGUOUS. It requires reconciliation, not automatic retry.
- The current Edge Function is not deployed and the permit path is not active in production. The existing checkout delivery chain remains unchanged.

## Validation

- Static contract tests cover exact-opportunity scoping, no caller-supplied recipient address, two live Shopify lookups, transient email handling, final database authorization and no-blind-retry behavior.
- Migrations 001–038 are applied to disposable PostgreSQL in the identity-v2 CI workflow.
- The pixel lifecycle SQL smoke test checks RLS, table grants, service-only RPC privileges, shared checkout/pixel reservation triggers and safe no-op behavior of the stale reconciler. It creates no customer, permit, attempt, reservation or provider request.
- A full positive-path SQL fixture and parallel cross-store pixel cost-cap race test remain outstanding; the existing checkout-vs-checkout race does not substitute for a pixel-specific race test.

No production operation is authorized by this branch work.
