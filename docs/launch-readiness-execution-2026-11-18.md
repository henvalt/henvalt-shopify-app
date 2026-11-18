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
