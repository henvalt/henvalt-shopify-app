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
