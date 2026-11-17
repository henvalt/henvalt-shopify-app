# HENVALT end-to-end launch readiness program

Audit date: 17 November 2026  
Status: preparation program; not a release authorization.

## Release rule

HENVALT is not launch-ready merely because OAuth, webhooks, n8n schedules or CI are green. Launch requires a complete, consent-compliant, exact-store journey from Shopify installation through recovery email, conversion suppression, confirmed attribution, merchant dashboard and auditable performance fee.

All changes remain preparation-only unless separate approval explicitly authorizes production migrations, deployments, workflow edits, app releases, merges or purchases.

## Verified live snapshot

### Supabase

Read-only inspection on 17 November 2026 found:

- 178 migrations recorded in the live project; latest migration is 14 November.
- 4 active Shopify connections across 3 tenants; one tenant has more than one active connection.
- 1 tenant membership.
- 3 customers, 2 checkouts, 5 opportunities and 5 recovery interventions.
- 3 delivery requests and 5 delivery attempts.
- 0 Shopify orders, 0 order attributions, 0 revenue-ledger rows and 0 Shopify privacy requests.\n- One billing account is PENDING in test mode, with a zero recurring amount and zero performance percentage; no billing measurements exist. The live configuration is not a production billing setup.
- Candidate V2 app registry, verified inbox, exact-store identity, order, recovery-candidate and recovery-opportunity tables are not present in live schema. Candidate migrations 001–013 have not been applied.

These are point-in-time aggregate counts, not proof of customer recovery.

### n8n

The three existing workflows remain active and unchanged:

- HENVALT_INGEST — 51 nodes.
- HENVALT_RECOVERY — 46 nodes.
- HENVALT_DELIVERY — 62 nodes.

Execution inspection from 14 November onward found 15 successful ingest executions, 4,586 recovery executions, and 9 successful plus 1 failed delivery executions. The latest sampled recovery executions succeeded. One sampled recovery run invoked browse, cart, checkout and deferred-payment discovery nodes but had no intervention item to process. A successful worker tick does not prove an email was sent.

The failed delivery execution was a manual one-off test. Node Record One-Off Test Result expected JSON but received a response that was not valid JSON; n8n recommended Text response mode. This is not evidence that the normal delivery path failed.

### Shopify and privacy runtime

- Deployed OAuth remains the legacy single-app implementation using one configured Shopify API key and secret. It does not persist app identity in OAuth state.
- Deployed privacy webhook remains the legacy single-secret path. Its shop-redaction path calls a tenant-wide redaction RPC, unsafe for a public multi-store product.
- App-aware OAuth, webhook ingress and privacy inbox exist only as branch candidates.
- V2 privacy inbox records verified requests for review; it does not complete exact-store export or deletion.

### Merchant dashboard

The existing Lovable dashboard uses the existing Supabase project.

Read-only source inspection confirms:
- Dashboard Edge Function requires exactly one active Shopify connection and rejects a tenant with multiple active connections.
- Revenue-ledger query filters by tenant, not immutable Shopify connection. A shop-specific request can return tenant-wide ledger rows.
- No completed authenticated store selector is connected to a server-validated store-selection API.
- Lovable project notes prohibit spending credits or publishing changes without explicit approval. No Lovable edits or deployments were made.

## Workstreams and release gates

### A. Public Shopify app identity and installation

Status: candidate implementation exists; live app remains legacy.

Required:
1. Create the Partner-owned public app only after account-owner approval and registration fee.
2. Store the new app client ID and secret through an approved secure process; never reuse the merchant-owned app secret.
3. Seed one active app-registry record for the new app.
4. Configure app-aware OAuth and validate state, HMAC, owner membership, shop and app identity.
5. Bind each installation to one immutable connection and issue a random per-install webhook route token; persist only its hash.
6. Register required commerce, uninstall and privacy webhook topics against app-aware routes.
7. Verify token refresh, reauthorization, uninstall, scope changes and revoked credentials.

Exit evidence: a real Partner-owned app installation completes OAuth, persists correct app/connection identity, registers webhooks, survives token refresh and deactivates safely on uninstall.

### B. Verified Shopify ingestion and exact-store identity

Status: candidate migrations 001–013 passed disposable-database validation and two-store SQL integration tests; none are live.

Required:
1. Apply only after production-schema parity review and separate approval.
2. Verify the actual Worker-to-Edge-to-Vault HMAC path with a real Shopify delivery.
3. Verify public-app Level 2 protected customer data approval for email before production contact resolution.
3. Project checkout, customer, session, pixel and order identities using immutable connection IDs.
4. Keep ambiguous historical events quarantined; never infer store identity from an unauthenticated shop header or ambiguous metadata.
5. Make duplicate deliveries idempotent and reject same delivery ID with a changed body digest.

Exit evidence: two real test stores can reuse checkout/customer/order identifiers without cross-store reads, writes or suppression.

### C. Recovery eligibility, contact resolution and consent

Status: eligibility candidate in migration 012 and exact-store opportunity promotion candidate in migration 013; contact resolution and V2 recovery sequence are not implemented. A branch-only exact-store consent evidence projector (migration 014) and checkout-country projector (migration 015) are now prepared; neither is applied or deployed.

Required:
1. Use the V2 exact-store candidate and opportunity layers, not legacy tenant-wide candidate readers.
2. Resolve contact only through the same verified Shopify connection and approved customer data scope. Public-app email access is Level 2 protected customer data and requires separate Shopify approval for the email field.
3. Require a verified recipient, explicit current marketing consent, jurisdictional eligibility, merchant recovery settings and store-scoped suppression.
4. Fail closed when customer ID, email, consent state, country or store identity is missing or ambiguous.
5. Re-check consent, opt-out, order status, store status, app status and tenant status immediately before each send.
6. Create exact-store opportunities, sequences and interventions with immutable source lineage.
7. Never allow an order from one store to suppress or bill a different store.

Exit evidence: a test checkout reaches an eligible intervention only when every exact-store and consent gate passes; negative cases fail closed with reason codes.

### D. Delivery, tracking, replies and cost controls

Status: existing three-workflow pipeline is active; V2 candidate queue is not connected to it. The live MailerSend Edge Function accepts recipient email from its caller and uses legacy tenant-scoped authorization; it is explicitly unsuitable for V2 sends.

Required:
1. Keep exactly three n8n workflows.
2. Add a V2 adapter only after the full opportunity/intervention/contact chain is store-safe.
3. Authorize each send server-side immediately before provider submission, verifying same-store lineage, current consent, suppression, idempotency and active entitlement.
4. Keep provider credentials server-side and merchant sender identity verified.
5. Prove delivery, bounce, complaint, unsubscribe and provider-event idempotency.
6. Keep customer replies as human-reviewed drafts for initial launch; do not auto-send AI replies.
7. Bound merchant-funded email usage and stop sends on uninstall, cancellation or entitlement failure.
8. Correct the one-off test result node response parsing in a separately approved n8n change.

Exit evidence: controlled test email reaches an authorized recipient, provider receipt is recorded, duplicate sends are prevented, unsubscribe blocks subsequent sends and uninstall stops queued work.

### E. Conversion, attribution and performance billing

Status: V2 order projection is implemented and tested in preparation branch; real order and attribution evidence is absent.

Required:
1. Match orders to checkouts by exact connection and Shopify checkout token.
2. Suppress recovery after order placement according to approved business rule.
3. Attribute only evidence-backed recoveries; distinguish confirmed from probable and never bill probable attribution.
4. Create one idempotent revenue-ledger entry per confirmed recovered order.
5. Calculate performance fee only after confirmed revenue is posted.
6. Make tenant-wide versus store-level billing explicit.
7. Reconcile refunds, cancellations, partial refunds and mixed currencies without duplicate charges.

Exit evidence: a real test order is matched to one exact-store recovery, appears once in dashboard, and creates the correct fee only after attribution is confirmed.

### E2. Performance billing\n\nStatus: the live billing account is pending/test-mode and has no measured usage or revenue. The database supports a percentage fee and Shopify usage-charge dispatch, but the current configuration is 0% and must not be mistaken for an approved commercial rate.\n\nRequired:\n1. Confirm the commercial performance percentage and whether the billing principal is merchant-wide or store-specific.\n2. Keep recurring subscription amount at zero for the performance-only model; charge only from confirmed recovered revenue.\n3. Require confirmed attribution and a posted revenue-ledger entry before creating a fee measurement.\n4. Make fee calculation, currency, refunds, caps, idempotency and Shopify usage-charge reconciliation auditable.\n5. Ensure the merchant can see the basis and amount before any usage charge is submitted.\n\nExit evidence: a test confirmed recovery creates exactly one correctly calculated fee; a probable or unconfirmed recovery creates no fee; refund/cancellation adjustments reconcile exactly once.\n\n### F. Merchant dashboard and onboarding

Status: existing UI exists; multi-store selection and store-scoped data contracts remain incomplete.

Required:
1. Add authenticated store discovery and selection; server-side membership checks bind the selected connection to the signed-in user.
2. Separate store-level analytics from merchant-account-wide analytics and label each clearly.
3. Scope store-specific metrics, activity, revenue rows and billing by immutable connection ID; quarantine legacy rows without trustworthy store lineage.
4. Make OAuth return, reauthorization, multi-store, empty, loading and failure states clear.
5. Keep metrics honest: no demo values, fabricated activity or estimated recovered revenue presented as confirmed.
6. Complete real password-reset email/token round trip, CAPTCHA provider acceptance and mobile/desktop accessibility checks.
7. Preserve the existing premium monochrome UI.

Exit evidence: a merchant with two stores can switch between them and sees only selected-store data; merchant-wide view is explicitly labeled and reconciles to its stores.

### G. Privacy, data rights and uninstall

Status: major public-launch blocker.

Required:
1. Implement exact-store customer data request, customer redaction and shop redaction processors.
2. Propagate immutable connection lineage through every customer, checkout, session, event, opportunity, intervention, delivery, suppression, conversation, attribution and ledger record.
3. Preserve unresolved historical data as unresolved; never delete or export an entire tenant for one store's request.
4. Verify mandatory Shopify privacy topics, signature, app identity, idempotency, deadlines, export retention and purge behavior.
5. Ensure consent withdrawal, unsubscribe, complaint and uninstall immediately prevent further marketing sends.
6. Prove Store A deletion cannot delete Store B records, even when the same tenant or customer identifier is shared.

Exit evidence: two-store export/redaction tests prove exact-store boundaries and preserve audit evidence without exposing another store's personal data.

### H. Public launch operations

Status: external prerequisites remain.

Required:
1. Owner-controlled Partner organisation access and public-app registration.
2. Shopify listing, app review, privacy policy, terms, support contact and data-retention disclosures.
3. Approved production app credentials and secure environment configuration.
4. Monitoring for OAuth, webhook failures, queue lag, provider failures, consent denials, billing reconciliation and privacy deadlines.
5. Rollback and incident-response plan.
6. Limited first-merchant rollout with explicit support and no unverified revenue claims.

Exit evidence: Shopify approval, production smoke tests, monitoring and rollback readiness, and owner-approved launch decision.

## Integrated end-to-end acceptance suite

Do not mark launch-ready until all are demonstrated:

1. Install app on Store A and Store B under supported merchant model.
2. Ingest checkout events from both stores, including repeated identifiers.
3. Reject invalid HMAC, wrong app, wrong store, revoked token and changed-body replay.
4. Detect inactivity only after configured policy window.
5. Resolve contact from correct store and require explicit current consent.
6. Send one branded test email through existing delivery workflow.
7. Verify delivery event, tracking click and unsubscribe; confirm no send after opt-out.
8. Place order in Store A and verify only Store A recovery is stopped.
9. Verify confirmed attribution and performance fee exactly once; test refunds and cancellation.
10. Verify Store A dashboard, Store B dashboard and merchant-wide totals do not leak or double-count.
11. Run customer data request, customer redaction and shop redaction for Store A; prove Store B remains intact.
12. Uninstall Store A and verify its tokens, keys, queued sends and webhook processing are disabled without disabling Store B.

## Next coordinated engineering actions

1. Complete one exact-store implementation tying candidate → opportunity → contact → consent → intervention → authorization → provider receipt → order → attribution → fee.
2. Implement and test V2 contact-resolution and delivery-authorization boundary without persisting unnecessary personal data.
3. Build exact-store privacy processor and immutable lineage before connecting V2 to legacy engine.
4. Prepare dashboard multi-store selection and scope contracts in dashboard source repository; do not publish or spend credits.
5. Prepare controlled n8n patch for one-off test parsing issue; do not edit active workflows without approval.
6. Keep public-app registration, production migration and release as explicit owner-controlled gates.

## Non-actions confirmed

No production Supabase migration, database write, Edge Function deployment, Cloudflare Worker deployment, n8n workflow edit, Shopify app change, public release, purchase or Lovable project edit was performed in this audit.


## New coordinated work added on 17 November

- Migration 014: exact-store email marketing consent evidence, append-only receipt history and replay-safe current-state projection. The projector ignores duplicate receipts, prevents older events from overwriting newer consent, and changes conflicting same-timestamp states to UNKNOWN.
- Migration 015: exact-store checkout country-code projection from the same verified checkout webhook receipt. Only ISO alpha-2 country code is persisted; no address, postal code or customer email is stored. Missing country remains unknown.
- Edge ingress candidate now runs checkout-country projection before acknowledging checkout webhook delivery.
- Added disposable SQL integration coverage for consent replay/order/timestamp conflicts and known/unknown checkout country.
- Added recipient resolution and single-use delivery authorization contract. The existing deployed MailerSend endpoint is explicitly excluded from V2 because it trusts caller-supplied recipient email and legacy tenant-scoped authorization.
- Shopify public app must request Level 2 protected customer data approval for email field before public production use. Development-store field selection is not production approval.
