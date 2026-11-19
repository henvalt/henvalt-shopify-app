# HENVALT integrated launch execution — 18 November 2026

Status: **PREPARATION ONLY — not launch-authorized**

This document replaces isolated ticket-by-ticket progress with one dependency-ordered
execution programme. It combines the current live runtime, the candidate repository,
and the active n8n pipeline. It is not permission to deploy, migrate production,
publish a Shopify app, alter n8n, spend money, or merge PR #6.

## 1. Verified live baseline

Read-only inspection was performed against the active Supabase project
`henvalt` (PostgreSQL 17.6). No rows or secrets were changed or exported.

### Database and migration parity

| Item | Live result |
|---|---:|
| Applied Supabase migrations | 178 |
| Latest applied migration | 20261114174204 |
| Candidate migrations 001–026 present in live history | 0 |
| Candidate V2 relations present in live `henvalt` schema | 0 |
| Tenants | 3 |
| Tenant memberships | 1 |
| Active Shopify connections | 4 |
| Tenants with multiple active Shopify connections | 1 |
| Customers / sessions / checkouts | 3 / 5 / 2 |
| Canonical events | 166 |
| Opportunities / recovery sequences / interventions | 5 / 3 / 5 |
| Delivery requests / delivery attempts | 3 / 5 |
| Orders / order attributions / revenue-ledger rows | 0 / 0 / 0 |
| Billing measurements | 0 |
| Shopify privacy requests | 0 |

The legacy core operational tables have no `shopify_connection_id` column in the
live schema. This includes customers, sessions, aliases, checkouts, canonical
events, opportunities, recovery sequences/interventions, messages, delivery
requests/attempts, orders, attributions, revenue ledger, conversations and
conversation messages. A tenant ID is not a substitute for immutable store
lineage when one tenant owns more than one Shopify connection.

Candidate migration 007 adds connection lineage only to a subset of legacy core
tables and deliberately does not backfill historical rows. Candidate V2 tables
are a parallel exact-store model, not proof that the live V1 records have been
reconciled.

### Deployed Edge Functions

The active project has legacy OAuth (version 27), token refresh (version 1),
privacy webhook (version 1), dashboard/control-plane functions, and the legacy
MailerSend delivery function. The candidate V2 identity, delivery, attribution,
uninstall and privacy processors are not deployed.

The live privacy endpoint is still the legacy single-secret implementation.
The V2 privacy processor and artifact registry are branch-only. Export
completion is intentionally held when historical tenant-scoped records cannot
be positively attributed.

### Dashboard correctness

The live `control_plane_dashboard_summary` selects a Shopify connection by
shop domain, but then aggregates opportunities, sent interventions, orders,
attributions and revenue ledger by `tenant_id`. It does not filter those
operational rows by immutable connection ID. This can present tenant-wide
figures as if they belong to one shop when a tenant has multiple active stores.

The separate merchant-dashboard endpoint currently rejects a tenant with
multiple active stores. That is safer than displaying cross-store data, but it
does not deliver the required store selector.

### n8n runtime

Exactly three production workflows remain active:

| Workflow | ID | Current observed execution evidence |
|---|---|---|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | 15 successful executions sampled since 14 Nov; last observed 14 Nov |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | 6,073 executions since 14 Nov; latest 100 sampled were successful and it continues on its schedule |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | 10 executions since 14 Nov: 9 success, 1 error |

Workflow inspection shows the ingest and delivery paths still call legacy
tenant-scoped RPCs such as `upsert_customer`, `upsert_checkout`,
`create_opportunity_idempotent`, `authorize_delivery_request`, and
`get_mailersend_token_for_delivery`. The V2 candidate queue is not connected
to these active workflows. A successful scheduled recovery tick is not evidence
that an email was sent or revenue was recovered.

The live legacy MailerSend token-release function contains a narrowly scoped
one-off test exception in its authorization predicate. It must be removed from
the public production path before launch; it must not be copied into the V2
authorization design. This document intentionally omits the recipient value.

## 2. The integrated critical path

The following work must be treated as one release chain. A downstream stage
cannot be declared ready while an upstream identity or evidence contract is
missing.

### Stage A — app ownership and install identity

- Establish a Partner-owned public app controlled by the HENVALT owner.
- Store that app's client ID/secret securely; do not reuse the legacy merchant
  app credentials.
- Use app-aware OAuth state and app-key resolution, immutable connection IDs,
  owner authorization, token refresh and per-install webhook route tokens.
- Prove install, reauthorization, scope update, uninstall and reinstall for two
  stores in one tenant.

**Exit evidence:** real installation records bind the correct app, tenant and
shop connection; no shop-domain-only token lookup remains.

### Stage B — database lineage and safe migration

- Reconcile the 178-migration live baseline with the candidate migration chain
  before any production migration is proposed.
- Propagate immutable connection lineage across every V1 operational family
  and V2 identity/recovery/delivery family.
- Backfill only from immutable, independently verifiable source evidence.
  Keep ambiguous historical rows unresolved; never infer store ownership from
  email, tenant membership, checkout token or session alias alone.
- Test migration application and rollback/forward recovery on a production-like
  clone, not only the synthetic CI baseline.

**Exit evidence:** a complete table/foreign-key lineage map, zero cross-store
foreign-key paths, explicit unresolved-row counts, and passing two-store tests.

### Stage C — one verified ingestion path

- Connect Shopify's raw-body HMAC verification to the app-aware ingress and
  verified inbox.
- Ensure route token, app key, shop domain, webhook ID, topic and body digest
  are bound before projecting events.
- Make duplicate delivery idempotent and reject a reused delivery ID with a
  changed body digest.
- Route checkout, cart, customer, order, refund, consent, uninstall and privacy
  events through exact-store projections.

**Exit evidence:** two stores can reuse customer/checkout/order identifiers
without cross-store reads, writes, suppression or conversion cancellation.

### Stage D — recovery and email delivery

- Keep exactly the existing three n8n workflows; introduce a V2 adapter into
  their event/worker/delivery boundaries rather than creating extra workflows.
- Promote only exact-store opportunities with verified identity, approved
  customer-data access, current consent, jurisdiction and merchant settings.
- Resolve recipients and authorize sends server-side immediately before
  provider submission.
- Remove the legacy one-off test authorization exception.
- Use MailerSend's current signed webhook contract, idempotent provider-event
  processing, single-use send permits and merchant-funded cost reservations.
- Stop queued sends immediately on unsubscribe, complaint, consent withdrawal,
  uninstall, app deactivation or tenant suspension.
- Keep AI replies as human-reviewed drafts.

**Exit evidence:** a controlled test message is authorized, sent once, tracked
through provider receipt, and blocked after each negative-state transition.

### Stage E — conversion, attribution and performance billing

- Match orders and refunds to checkouts using exact connection identity.
- Suppress recovery only for the matching store.
- Attribute only evidence-backed recovered orders; probable attribution is
  visible as probable but never billable.
- Create one idempotent ledger measurement per confirmed recovery.
- Reconcile cancellations, full/partial refunds, currency and billing caps.
- Keep performance-only billing at zero until a merchant-approved rate and
  billing principal (merchant-wide or per-store) are configured.

**Exit evidence:** one real test recovery produces one confirmed order, one
ledger row and one correctly calculated fee; retries and refunds reconcile
exactly once.

### Stage F — merchant dashboard and onboarding

- Add server-validated store discovery and selection, bound to the signed-in
  user's membership.
- Make every store-specific query filter by immutable connection ID.
- Label merchant-wide totals explicitly; do not label tenant-wide legacy data
  as store-specific.
- Quarantine unresolved legacy metrics rather than guessing.
- Preserve the monochrome dashboard and real-data-only metric policy.
- Verify mobile sign-in, password reset, onboarding, empty/loading/error states
  and multi-store switching.

**Exit evidence:** a merchant with two stores can switch between them and each
view contains only that store's attributable data; merchant-wide totals
reconcile to the store views.

### Stage G — privacy, uninstall and retention

- Recover and version-control every deployed compliance handler before
  replacement.
- Complete exact-store customer export, customer redaction and shop redaction.
- Reuse the same lineage map for export, redaction, delivery suppression and
  uninstall stop controls.
- Retain ambiguous historical records for review rather than exporting or
  deleting tenant-wide data on behalf of one store.
- Verify deadlines, artifact delivery, retention expiry and confirmed purge.

**Exit evidence:** Store A's data request/redaction cannot expose or delete Store
B's records, and every completion response has durable evidence.

## 3. Current launch decision

**Not launch-ready.** The blockers are connected, not independent:

1. Public app ownership/credentials are not yet under the current HENVALT
   owner's control.
2. Live database has no candidate V2 relations and no immutable connection
   lineage on the V1 operational families.
3. Active n8n workflows still use legacy RPC contracts.
4. Legacy delivery authorization contains a one-off test exception.
5. Dashboard summary is tenant-scoped despite multi-store tenancy.
6. No real order, confirmed attribution, revenue-ledger entry or billing
   measurement exists.
7. Privacy processing is still legacy in production; V2 export is deliberately
   incomplete pending lineage coverage.

A green CI run validates the candidate branch against its disposable fixture;
it does not close any of these live-runtime gates.

## 4. Execution and safety rules

- Continue engineering on PR #6 or a linked preparation branch.
- Keep the three active n8n workflows unchanged until an explicitly approved
  staged cutover is ready.
- Do not apply migrations, deploy Edge Functions/Workers, alter Shopify app
  settings, publish workflows, change billing, or purchase services without
  separate explicit approval.
- Every implementation batch must include cross-system contract tests and
  verification evidence.
- Do not mark launch-ready until the complete chain from install to confirmed
  recovered revenue and privacy-safe uninstall has been demonstrated.


## 5. Candidate-to-runtime integration gaps found during code-path tracing

The candidate Edge Functions and SQL migrations provide several strong
components, but they do not yet form one connected execution path:

- **OAuth configuration mismatch:** the checked-in `shopify.app.toml` still
  points to the legacy dashboard URL and legacy OAuth callback and retains
  `use_legacy_install_flow = true`. The candidate OAuth V2 handler resolves
  app identity through the app registry, but the app configuration has not
  been regenerated from an owner-controlled public app. Do not release this
  configuration as-is.
- **Ingress-to-recovery gap:** the candidate
  `henvalt-shopify-webhook-ingress` verifies and projects checkout, consent,
  order and refund events. It does not itself hand a durable V2 recovery job
  to the active `HENVALT_RECOVERY` workflow. The active recovery workflow
  continues to call legacy tenant-scoped RPCs. A durable, idempotent V2
  orchestration adapter is still required.
- **Delivery integration gap:** `henvalt-shopify-contact-delivery-v2` is a
  candidate direct Shopify-to-MailerSend boundary. It uses the V2 resolver,
  single-use permit and cost-reservation chain, but the active
  `HENVALT_DELIVERY` workflow still invokes the legacy
  `authorize_delivery_request` and `henvalt-mailersend-delivery` path. The
  cutover needs one clearly defined owner for scheduling, final authorization,
  provider submission and outcome reconciliation; do not run both paths for
  the same intervention.
- **Privacy processor boundary:** `henvalt-shopify-privacy-v2` durably records
  verified receipts and explicitly responds that review is required. The
  export processor is a separate candidate function, currently blocked by
  legacy-scope completeness. A webhook HTTP 200 therefore means receipt
  acceptance, not completed export or deletion.
- **Dashboard contract gap:** candidate V2 migrations add exact-store identity,
  recovery and billing tables, but there is no completed store-selection API
  and no V2 dashboard summary contract replacing the live tenant-wide summary.
  The current single-store endpoint remains fail-closed for multi-store
  tenants; the control-plane summary remains unsafe for shop-specific
  multi-store reporting until replaced.

These findings mean the next implementation batch must connect the V2
identity graph to the three existing workflows, the merchant dashboard and
the compliance lifecycle as a single controlled cutover. Merely deploying the
candidate Edge Functions one by one would leave an incomplete or duplicated
recovery system.


## 6. Recovery coverage: V2 currently implements checkout only

The migration code confirms that the V2 recovery pipeline is narrower than
HENVALT's intended product scope:

- `shopify_checkout_recovery_candidate_v2` is explicitly checkout-token based.
- `shopify_recovery_opportunity_v2.opportunity_type` is constrained to
  `ABANDONED_CHECKOUT`.
- The candidate refresh/promotion RPCs are
  `refresh_shopify_checkout_recovery_candidates_v2` and
  `promote_shopify_checkout_recovery_candidates_v2`.
- The Web Pixel V2 inbox accepts `page_viewed`, `product_viewed`,
  `product_added_to_cart`, `product_removed_from_cart` and
  `checkout_started`, but migration 008 deliberately stores them as
  `PENDING_ADAPTER` and states they are not connected to canonical events,
  recovery, delivery, attribution or billing.
- The identity graph projection creates pseudonymous customer/session/alias
  identities; it does not create browse/cart recovery opportunities.

Therefore **V2 abandoned-cart and browse-abandonment recovery are not yet
implemented end-to-end**. The active V1 n8n pipeline contains those flows,
but those flows still use legacy tenant-scoped records. We must not silently
drop them during cutover or claim that the V2 checkout pipeline covers them.

The required V2 extension is a generalized, exact-store source-candidate and
opportunity model that can represent checkout, cart and browse without
pretending that a checkout token exists for every event. It must preserve
consent separation: analytics permission may allow pseudonymous event
processing, but it does not imply email-marketing consent. Browse product
context must be explicitly validated and bounded before it is retained. The
same exact-store contact, suppression, jurisdiction, conversion, attribution
and billing gates must then apply to all three recovery types.

**Cutover rule:** keep the existing V1 cart/browse path out of any V2 release
until the V2 candidate model and two-store integration tests cover it. If the
first controlled release is intentionally checkout-only, disclose that scope
and keep the other flows disabled rather than routing them through ambiguous
legacy records.


## 7. Active recovery runtime trace — cart and browse are V1, not V2

A read-only trace of the three active n8n graphs and the live PostgreSQL
function definitions refines the recovery-coverage finding:

- `HENVALT_RECOVERY` actively calls all three legacy discovery functions:
  `process_abandoned_checkout_candidates`,
  `process_abandoned_cart_candidates` and
  `process_browse_abandonment_candidates`.
- Its worker context and email-preflight code already understands
  `ABANDONED_CHECKOUT`, `ABANDONED_CART` and `BROWSE_ABANDONMENT`.
  That is copy/worker compatibility, not proof of safe store identity.
- The live cart candidate query joins `shopify_connections` by
  `tenant_id` and `active=true`, without binding the canonical cart snapshot,
  pixel event and customer to the same immutable connection.
- The live browse candidate query has the same tenant-only connection join.
  Its session activity and checkout suppression subqueries are also scoped
  by tenant/session rather than an immutable store connection.
- Both legacy processors write into the tenant-scoped `opportunities`,
  `recovery_sequences` and `recovery_interventions` model. The active
  recovery worker then claims and processes those legacy interventions.
- The candidate V2 pixel inbox is not the source for these legacy discovery
  functions; it remains `PENDING_ADAPTER`. Thus V1 and V2 are separate
  event/identity paths today.

This matters because a tenant currently has more than one active Shopify
connection. A join on tenant plus active status can multiply a candidate or
associate it with the wrong shop. The cart query also matches a pixel event
to a cart snapshot using tenant/session/product data without an exact-store
key. The browse query's suppression checks can likewise observe activity
from another store when session references collide.

### Required remediation before recovery cutover

1. Do not feed legacy cart/browse opportunities from ambiguous tenant-only
   records into the V2 delivery path.
2. Preserve V1 recovery only for a demonstrably single-install tenant where
   every source event, customer, session, checkout and intervention can be
   positively bound to the same immutable connection. A count of active
   stores alone is not enough; historical connections and unresolved lineage
   must be considered.
3. Build the V2 event adapter from the verified pixel inbox into exact-store
   session/customer/event context. It must persist bounded product/cart
   context only under analytics consent and evaluate marketing consent
   independently at send time.
4. Generalize the V2 source-candidate/opportunity model to represent cart and
   browse without inventing checkout identities. Recheck same-store order,
   checkout progression, customer suppression, uninstall and current consent
   before promotion and again before delivery.
5. Keep the three-workflow architecture. HENVALT_INGEST accepts verified
   source events; HENVALT_RECOVERY runs the exact-store candidate/claim worker;
   HENVALT_DELIVERY performs final authorization, provider send and
   reconciliation. Use a durable idempotent handoff, not a fourth workflow
   and not a parallel direct-send path.
6. Cut over one recovery type at a time behind a tenant/store feature gate.
   Prove two-store collision tests and a no-duplicate-send test before enabling
   each type. Retain a rollback switch that stops new V2 promotion without
   reopening ambiguous V1 sends.

**Current decision:** the existing V1 cart/browse functions are real and
active, but they are not safe evidence for multi-store launch. The V2 pixel
inbox and checkout-only opportunity model do not yet replace them. No active
n8n workflow or live database function was changed during this trace.


## 8. Implemented candidate-stage cart/browse foundation — branch only

The following additive preparation changes are now in the branch:

- The pixel inbox ingestion function retains a bounded allowlist of product and
  cart-line context only when analytics processing is allowed. It does not
  retain arbitrary nested browser payloads, query strings, or fragments.
- The Cloudflare pixel collector forwards bounded product ID/title/variant,
  quantity, unit/line amount and currency fields to the server-side validator.
- Migration
  `202611180027_shopify_pixel_recovery_candidates_v2.sql` adds a server-only
  candidate table with composite exact-connection foreign keys to the tenant,
  session identity, optional customer identity and source inbox event.
- The candidate refresh RPC recognizes two distinct signals:
  - abandoned cart from a product-added-to-cart event;
  - browse abandonment from at least two product views of the same product.
- Both paths use same-store session activity and suppress on later checkout
  progression. Cart candidates also suppress on same-product removal; browse
  candidates suppress when that product is subsequently added/removed.
- Candidate processing is gated by analytics consent and active tenant/store/
  app identity. Marketing consent is not inferred from analytics consent and
  is not treated as send authorization.
- Candidate rows contain no email address and cannot create a recovery
  opportunity, sequence, intervention, send attempt, provider request,
  attribution or billable measurement. Final contact consent and suppression
  must be rechecked by the future delivery boundary.

### Verification evidence

The disposable PostgreSQL CI suite applied migrations 001–027 and executed a
new two-store integration test. It reused the same browser, customer and
product identifiers in two stores, created cart and browse candidates in both,
then removed a cart item in Store A. The test confirmed that only Store A's
cart candidate was suppressed and Store B remained eligible. It also ran with
analytics consent true and marketing consent false, demonstrating that
candidate analytics processing does not itself authorize marketing sends.

The latest completed validation at the time of this update passed:
- candidate SQL migration application;
- the two-store cart/browse candidate integration test;
- the pixel cart/browse contract tests;
- the existing identity, checkout, conversion, privacy and delivery contract
  suite up to the currently executing final steps.

This is a candidate-stage milestone, **not an end-to-end recovery launch**.
The next gate is to generalize the V2 opportunity source model and bind these
candidates to the existing single-use delivery authorization and the three
existing n8n workflow boundaries. Do not enable candidate promotion or sends
until that integration has its own two-store, consent-withdrawal, conversion,
uninstall and duplicate-send tests.


## 9. Generalized opportunity promotion — metadata only

Migration
`202611180028_shopify_general_recovery_opportunities_v2.sql` extends the
V2 opportunity record so it can reference either:
- a checkout recovery candidate plus its checkout identity and verified webhook
  receipt; or
- a cart/browse pixel candidate plus its exact-store source identity.

A database check constraint enforces those two mutually exclusive source
shapes. The cart/browse promotion RPC rechecks active app/store/tenant state
and same-store orders, then creates idempotent opportunity metadata and marks
the source candidate promoted. The two-store integration test now verifies
that Store A's removed-cart candidate is suppressed, Store B remains eligible,
and only the three remaining candidates become opportunities.

**Delivery remains deliberately closed for cart/browse.** The existing V2
single-use permit and contact-resolution functions still join the checkout
candidate and checkout identity tables. They cannot authorize a pixel-backed
opportunity. No intervention, send permit, MailerSend request, attribution or
fee measurement is created by this new promotion function.

The full disposable PostgreSQL identity workflow passed on commit
`4e123b5`, including migrations through 028, the two-store cart/browse
candidate and opportunity-promotion integration test, and the existing
checkout, privacy, delivery and cost-reservation tests. The subsequent
workflow-title/document commits do not alter application code. A new CI run
is being triggered for the updated branch head.


## 10. Pixel opportunity contactability gate — fail closed

A follow-up review found that the first generalized promotion draft used the
presence of a pixel customer identity to set a cart/browse opportunity to
`CONTACT_RESOLUTION_PENDING`. That state was too optimistic: a customer
identity reference does not prove a usable email, current marketing consent,
or a trusted country/jurisdiction. Pixel analytics consent is separate and
cannot be reused for marketing authorization.

Migration 028 now keeps every pixel-backed cart/browse opportunity in
`REVIEW_REQUIRED`, even when a customer identity exists. The source candidate
may be promoted as metadata, but a later, separately verified resolver must
establish contactability and policy evidence before any transition toward
delivery. A static regression test prevents reintroducing the identity-only
shortcut.

This change does not alter the checkout path, delivery permits, provider
submission, or production services. It is branch-only and must pass the
updated CI run before being treated as validated.



## 11. Cart/browse contact and jurisdiction delivery gate — traced

A code-path trace of migrations 003–008 and 028 confirms that the current delivery boundary remains checkout-specific:

- The contact resolver, permit issuer and permit consumer join the checkout recovery candidate and checkout identity. Pixel opportunities intentionally have NULL checkout references and cannot pass those joins.
- Permit issue and consumption recheck current exact-store marketing consent, supported checkout jurisdiction, same-store order state, suppression and app/store/tenant/provider/sender/billing state. The permit is short-lived and single-use.
- The existing cost-reservation trigger is merchant-wide: it locks the tenant billing-account row, checks provider unit cost in merchant billing currency, aggregates RESERVED and SETTLED reservations across stores, checks monthly email count and inserts the reservation in the send-attempt transaction. AMBIGUOUS provider outcomes retain the reservation.
- Jurisdiction evidence currently comes from a verified checkout shipping/billing country code. Cart/browse sessions without checkout country evidence cannot use storefront locale, currency, browser locale or IP inference as a substitute.

A new branch-only contract and CI test were added:
- `docs/shopify-pixel-contact-jurisdiction-delivery-gate-v2.md`
- `tests/shopify-pixel-contact-jurisdiction-delivery-gate-v2.test.mjs`

The test locks the current checkout-only permit boundary, exact-store timestamped consent, checkout-derived jurisdiction, merchant-wide atomic reservation and PII/ambiguous-send restrictions. It is wired into the existing V2 validation workflow.

**Decision:** do not generalize the permit SQL by simply making checkout joins optional. The next implementation needs a separate trusted customer-contact/country evidence path for pixel opportunities, then one shared authorization transaction that binds the source shape and reuses the existing consent, suppression, conversion, sender and merchant-wide cost reservation controls. Until that exists, cart/browse remain review-only and no customer send is authorized.


## 12. Exact-store customer contact evidence receiver — implemented, resolver still open

Candidate migration 029 adds append-only and current-state contact evidence tables plus a service-role-only RPC. The database accepts only exact-store customer identity references and stores a boolean contact-availability result, optional normalized country code, timestamp and opaque lookup ID. It never stores the email, address, phone, Shopify token or raw Admin API response.

The current-state row has a composite evidence foreign key binding tenant, connection and customer identity. The RPC checks active app/store/tenant, exact-store customer identity, narrow evidence freshness, and lookup replay consistency. A newer observation wins; stale observations cannot win a concurrent first-write race.

The existing two-store pixel integration test now verifies:
- Store A and Store B have separate customer identity rows despite reusing the same external customer reference.
- Store A contact evidence is accepted only for Store A.
- Store A identity submitted under Store B is rejected.
- An unavailable contact is recorded without storing the contact value.
- Reusing a lookup ID with changed country facts is rejected.
- Evidence creation returns `send_authorized=false`.

The new migration is included in disposable CI migration application (001–029), and the static contact-evidence contract test is included in the V2 Node suite.

**Not yet implemented:** the trusted Edge Function that calls Shopify Admin GraphQL for the exact connection, verifies email availability and trusted country, and keeps the email transient through final delivery. Migration 029 is only the evidence receiver; it is not a contact resolver, permit issuer or send authorization. Cart/browse remain review-only. Latest changes require their own green CI run before this slice is considered validated.

## 13. Bounded request ingress hardening — branch implementation

The checkout delivery and MailerSend provider-event ingress now share
`supabase/functions/_shared/request-body-v2.ts`.

- Both paths enforce byte ceilings while reading the request stream. The
  declared Content-Length is an early rejection hint only; the streamed byte
  count remains authoritative when the header is absent or inaccurate.
- Checkout delivery accepts only a JSON object with the documented
  `intervention_id`, `subject`, `html` and `text` keys. It rejects
  unexpected keys, malformed JSON, invalid UTF-8, non-object bodies and
  oversized requests before resolving any delivery context.
- MailerSend provider ingress requires JSON content type and caps the raw
  signed body at 1 MB before forwarding its exact bytes to the signature-
  verifying database RPC. It parses the verified body defensively before
  extracting the provider event ID used for pixel-attempt reconciliation.
- Stream cancellation occurs as soon as the byte ceiling is exceeded. The
  helper does not log request bodies, recipient values, signatures or tokens.

Regression contracts are in
`tests/shopify-request-body-hardening-v2.test.mjs`; CI now includes the new
test and type-checks the checkout delivery Edge Function. These are candidate
branch changes only. They do not alter the live webhook route, provider
settings, n8n workflows, database or deployment.

This closes an ingress resource-boundary gap; it does not close the broader
launch blockers in app ownership, production migration parity, n8n V2
orchestration, verified sender/billing configuration, real recovery testing,
or Shopify privacy approval.

## 14. Dashboard date and asynchronous-state hardening — branch implementation

Both authenticated dashboard Edge Function routes now use the shared
`date-range-v2.mjs` validator. It rejects impossible Gregorian dates
(for example, February 31), malformed date-only values, reversed ranges and
ranges longer than 366 days. This avoids JavaScript date-parser rollover
silently converting invalid merchant query parameters into a different day.

The dashboard browser client now aborts superseded requests when the merchant
changes store or date range, ignores responses from older request generations,
and invalidates outstanding work on sign-out. Merchant metrics and activity
are cleared from the rendered view when the owner session ends. The loading/
status regions announce updates to assistive technology.

Regression tests cover leap-year validation, inclusive range bounds, both
dashboard API routes, stale-response suppression, abort handling and
sign-out clearing. These changes affect only candidate code and the static
dashboard artifact; no Pages deployment or live Edge Function update occurred.
The dashboard's Auth, database lookup and summary calls also now have explicit
10–12 second network deadlines. A stalled upstream service therefore returns
the dashboard's bounded error response instead of leaving a request open
indefinitely.

## 15. Full repository verification and secret scanning

The repository now exposes `npm test` for every `tests/*.test.mjs` file
and `npm run check` for the configured Edge Function type checks. The
identity validation workflow runs both scripts in addition to the focused V2
suite and disposable PostgreSQL integration.

The latest successful pull-request validation on commit
`02f3a99665731bb86bcb05ffeb7987a8b2d895e3` reported:

- 322/322 complete repository Node tests passed.
- 209/209 focused V2 Node contract tests passed.
- Gitleaks scan passed with full Git history available.
- Configured Deno checks passed.
- Candidate migrations 001–043 and the complete disposable PostgreSQL SQL
  integration/concurrency suite passed.

The new dashboard HTML safety tests cover escaping of merchant/event-derived
values and verify that sensitive recipient/provider fields are not rendered.
The deployment-workflow safety tests assert that Shopify production release
and unreleased-version preparation are manual-only operations.

These are candidate-branch checks, not production runtime verification.

## 16. Shopify deployment and release gates

The Shopify configuration workflow's app-preparation job now runs only for an
explicit `workflow_dispatch` with `confirm_shopify_prepare=true` from
`main`. It can create an unreleased app version and is not part of ordinary
push/PR validation.

The separate production release workflow no longer has a push trigger. It
requires `workflow_dispatch`, `confirm_release=true`, the `main` branch
and the configured Shopify service-account secret. The release job remains a
distinct production action.

A repository regression test checks both conditions. These gates reduce
accidental releases; they do not make the checked-in Shopify app configuration
release-ready. The app TOML still contains legacy URLs and install-flow
settings, and the owner-controlled app identity and Pixel UID remain open.

## 17. Trusted recovery message rendering and provider unsubscribe gate

The candidate branch now includes migration
`202611190001_shopify_recovery_message_context_v2.sql` (migration 044),
which adds a service-role-only exact-store message-context resolver. It returns
only a canonical Shopify store domain and one of the three allowlisted
opportunity types. It does not return recipient PII, provider secrets or
delivery authority.

The shared `recovery-message-v2.mjs` module produces fixed checkout, cart and
browse templates. Merchant display branding comes only from the verified
sender profile and is HTML-escaped. Delivery Edge Functions now reject all
caller-supplied message fields and accept only `intervention_id` or
`opportunity_id`; n8n no longer supplies the subject or body.

Each template includes MailerSend's `{{unsubscribe}}` placeholder in HTML and
plain text. Before provider submission, the trusted Edge Function checks the
exact sender domain through MailerSend's domains API and requires verified
domain status plus HTML and plain-text unsubscribe tracking. Any missing,
unverified, disabled or unreachable domain configuration blocks the send.

Checkout and pixel provider request failures now both preserve AMBIGUOUS
outcomes and reservations when the provider may have accepted a request.
Neither path tells n8n to blindly retry an ambiguous item.

The current CTA deliberately links to the canonical verified Shopify store
root. It does not pretend to resume an abandoned checkout; a checkout deep link
or item-level personalization requires a future trusted exact-store context
source. Both V2 delivery Edge Functions also fail closed unless the operator has explicitly set `HENVALT_V2_MAILERSEND_EVENTS_READY=true` after verifying the signed V2 provider-event route and disabling duplicate legacy processing. The production n8n workflows remain unchanged and no provider send
was performed.

The disposable concurrency setup now also checks that the pixel message
context RPC returns the exact Store B domain and opportunity type, with
explicit no-PII, no-secret and no-delivery-authority flags. The CI workflow
applies candidate migrations 001–044 in its disposable PostgreSQL database.

## 18. Active n8n graph inspection and privacy boundary

A second read-only inspection of the active `HENVALT_RECOVERY` and
`HENVALT_DELIVERY` workflow graphs confirmed that the current production
versions still execute the legacy tenant-scoped pipeline. Recovery loads the
legacy worker context, constructs AI copy context, writes a legacy message
record and delivery request, then passes recipient, subject, HTML and text to
the existing Delivery subworkflow. Delivery still calls the legacy
`henvalt-mailersend-delivery` Edge Function.

The legacy Recovery AI context includes customer first name, product details,
previous message bodies, recipient reference and destination URL in n8n
execution items. The n8n execution-retention/redaction configuration was not
verified during this inspection. This is a data-minimization and privacy
review item before launch. V2 deliberately removes recipient and body data
from n8n execution items; the active legacy graph has not been changed.

The current Delivery workflow also receives MailerSend event webhooks through
its own raw-body webhook, calls the legacy
`verify_mailersend_webhook_signature_api` RPC, then processes events with
`process_mailersend_webhook_event`. This must be cut over to the V2 signed
Supabase Edge Function as one route, with no dual processing. Both V2
delivery functions now fail closed unless
`HENVALT_V2_MAILERSEND_EVENTS_READY=true` is explicitly set after that
cutover has been verified.

No active workflow was updated, unpublished, published or executed during
this inspection.

## 19. Exact active n8n version IDs and ingress overlap

Read-only metadata inspection confirmed the three active workflow versions:

- `HENVALT_INGEST` — `VTpfGKNtu1CSQ4Rv`, active version
  `6368d539-708f-494a-8be8-b9601d0e8607`.
- `HENVALT_RECOVERY` — `3GEDoeCA4paXTaDF`, active version
  `32e50bf7-4cbd-4070-bbba-f259ed17b369`.
- `HENVALT_DELIVERY` — `CvVyybGJZSnklxiZ`, active version
  `621ae6ce-a006-4fed-a70e-acf774c360fb`.

The active Ingest graph's `henvalt/ingest` webhook verifies Shopify HMAC,
resolves the legacy tenant, writes canonical events and checkout projections,
and handles order attribution, recovery stop, uninstall, payment and refund
events. These responsibilities overlap the V2 Worker/Edge receipt and
projection path. Cutover must route each store/topic to one authoritative
path; do not globally disable the legacy workflow and do not double-project
the same V2 event.

The active Recovery and Delivery graph details are captured in
`docs/n8n-v2-cutover-boundary.md`. No active workflow was edited, executed,
unpublished or republished during this inspection.
