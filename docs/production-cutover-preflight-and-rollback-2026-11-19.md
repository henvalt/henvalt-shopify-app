# HENVALT production cutover preflight, execution gates and rollback contract

**Decision: HOLD.** This is an operator checklist for a future, separately approved release. It is not permission to pause legacy workflows, apply migrations, deploy code, change Shopify settings, route provider events, send email, or bill merchants.

## 1. Scope and invariants

The candidate V2 system is not production-parity verified. Candidate migrations 001–058 have passed disposable PostgreSQL CI; this proves migration-chain behavior against the CI baseline, not compatibility with the live database's 178-migration history or its existing rows.

The following invariants apply throughout the cutover:

- Exactly three existing n8n workflows remain: `HENVALT_INGEST`, `HENVALT_RECOVERY`, and `HENVALT_DELIVERY`. Do not create a fourth workflow.
- A Shopify event, MailerSend event, recovery opportunity, or customer message must have one authoritative processing path at a time. No V1/V2 dual ingress, duplicate event receiver, or duplicate send path.
- The V2 delivery boundary accepts opaque work IDs. Customer PII, message bodies, Shopify access tokens, MailerSend tokens, and fingerprint secrets must not be copied into n8n execution items.
- Email acceptance, delivery, open, or click is not recovered revenue. Only exact-store paid-order attribution, adjusted for refunds and idempotently reconciled, can support a performance-fee measurement.
- An AMBIGUOUS provider submission is reconciled, never blindly retried.
- Every stage is fail-closed. Missing identity, consent, jurisdiction, sender, cap, provider, webhook, privacy, or attribution evidence means no promotion or send.

## 2. Gate A — ownership and release authority

Before staging or production work, record affirmative owner control of:

1. Shopify Partner organization and the exact public app/client identity.
2. Supabase project, database backup/restore, Vault and Edge Function deployment.
3. Cloudflare account, Worker route, secrets and deployment history.
4. All three n8n workflows, credentials and execution-retention settings.
5. MailerSend account, verified sender domain, API credentials and signed webhook configuration.
6. GitHub repository, branch protections and deployment secrets.
7. Merchant billing principal, approved performance percentage, provider-cost funding and legal terms.

Do not rely on a former collaborator's Shopify app, Worker hostname, server, credentials, or account ownership. The checked-in Shopify TOML, deployed runtime secrets, app registry row and actual callback configuration must be compared against the owner-controlled values; never infer missing URLs or secrets.

**Abort Gate A** if any owner, app ID, callback, secret owner, deployment target or workflow owner is unclear. No migration or service pause is authorized by this document.

## 3. Gate B — production parity and historical data reconciliation

The live database must be inventoried independently before preparing a production migration:

1. Capture the exact live migration history, schema objects, extensions, roles, grants, RLS policies, triggers, indexes, constraints, RPC signatures and Edge Function inventory.
2. Export counts and scoped samples for every legacy table that overlaps candidate store, checkout, customer, consent, opportunity, intervention, delivery, provider-event, attribution, billing and privacy lineage.
3. Map each candidate foreign key to its actual production parent key. Do not assume a tenant-wide customer or checkout reference is an exact Shopify connection identity.
4. Identify collisions, orphan rows, duplicate event IDs, stale OAuth connections, missing store IDs, terminal states, already-sent interventions, provider attempts and financial rows.
5. Produce an explicit disposition for each historical population: preserve, map, quarantine, reconcile manually, or exclude. Never silently coerce uncertain legacy rows into V2 eligibility.
6. Review all 047 candidate migrations in order against the live schema. Identify object-name collisions, existing policies/grants, lock-heavy operations, table rewrites, FK validation cost and any statement that is not safe to re-run.
7. Build a production-like clone from a restorable backup and replay the exact candidate chain. Record pre/post row counts, constraints, index validity, function grants, query plans, lock duration, runtime and data diffs.
8. Verify backup restoration in an isolated environment. A backup that has not been restored is not a rollback plan.

Required artifact: a signed parity report containing object-by-object differences, historical-row dispositions, migration timings, unresolved discrepancies and named approvers.

**Abort Gate B** if a historical row cannot be assigned to an exact store/connection, if a migration unexpectedly changes legacy rows, if constraints fail, if locks exceed the agreed window, or if the clone cannot be restored and replayed.

## 4. Gate C — no-send cutover rehearsal

Before any production route change, rehearse with a dedicated owner-controlled test shop and delivery disabled:

1. Confirm the app registry, Shopify client ID, callback URI, privacy route and Pixel UID all belong to the current owner-controlled app.
2. Verify OAuth install, reauthorization, offline-token refresh, uninstall and reinstall. Confirm the correct store and tenant are linked exactly.
3. Send signed test webhooks for checkout, order, refund, uninstall and privacy topics. Prove raw-body HMAC verification, durable receipt, idempotency and exact-store projection.
4. Confirm duplicate Shopify deliveries do not create duplicate canonical events, candidates, interventions or work claims.
5. Confirm consent withdrawal, unsubscribe, complaint, bounce, jurisdiction denial, inactive store, missing sender, missing provider readiness and exhausted merchant cap all produce zero provider submissions.
6. Confirm checkout and pixel candidates remain separate, checkout closed/converted states remain terminal, and pixel marketing consent is independently required.
7. Run Recovery against disposable/test data with Delivery mocked or explicitly no-send. Verify full-batch validation occurs before the first handoff, leases are exact and stale workers cannot finish reclaimed work.
8. Verify Delivery receives only opaque identifiers and cannot accept caller-supplied recipient, subject, HTML, text, store domain or template fields.
9. Exercise all provider outcomes: definite rejection, accepted response, timeout, transport exception, 408/5xx, malformed response and post-submit ledger uncertainty. AMBIGUOUS must remain held for reconciliation.
10. Verify MailerSend signed webhook raw-body handling, event idempotency, suppression updates and ambiguous-attempt reconciliation in a non-production endpoint.
11. Inspect n8n execution data and error paths for PII, message content, access tokens, provider tokens and secrets. Verify retention/redaction controls rather than assuming them.
12. Prove dashboard values reconcile to exact-store source rows, sign-out clears tenant metrics, and date-range/cancellation behavior cannot leak stale data.

The legacy manual one-off sender branch containing a historical request/recipient is a mandatory review/removal item before any production Delivery workflow activation. It must not be executed during rehearsal.

**Abort Gate C** on any unexpected network call, provider submission, PII/token leakage, duplicate processing, wrong-store join, consent bypass, non-idempotent event, unexplained dashboard value or unconfirmed lease finish.

## 5. Gate D — staged execution order (each stage separately approved)

No stage below is implied by approval of another stage.

1. **Change freeze and evidence capture.** Record current workflow active versions, Shopify subscriptions, Worker version/routes, Edge Function versions, secrets inventory (names and presence only), MailerSend event destinations and production migration history. Export restorable configuration. Do not expose secret values in the release record.
2. **Traffic containment.** Under an explicit maintenance approval, prevent new legacy recovery sends and identify in-flight provider requests. Preserve event intake if it is safe and non-duplicative. Do not simply deactivate all three workflows without understanding their ingestion, refund, uninstall and privacy responsibilities.
3. **Database stage.** Apply only the separately reviewed production migration plan after a verified backup and successful clone rehearsal. Run post-migration catalog, grants, RLS, row-count and RPC contract checks before any application traffic is routed. Candidate CI order is not by itself production authorization.
4. **Secrets and Edge Functions.** Configure owner-controlled secrets and Vault references. Deploy only the functions whose schema dependencies are verified. Confirm health, expected authentication failures, rate/body limits and sanitized logs.
5. **Worker and Shopify ingress.** Deploy to an owner-controlled test route first. Verify per-install route tokens and signed raw-body receipts. Switch one webhook topic/store at a time only when exactly one receiver is active and durable acceptance is proven.
6. **n8n draft cutover.** Keep the same three workflow identities. Import reviewed native-node changes as inactive drafts, verify RPC arguments, credentials, timeouts, worker identity and execution-data redaction. Recovery owns lease completion; Delivery routes/classifies only. Ingest must not duplicate Shopify ingress.
7. **Provider event receiver.** Prove V2 signed MailerSend test callback and all reconciliation/suppression event types. Switch to one event receiver only after the legacy receiver is disabled in a controlled, observable step. Set the V2 readiness flag only after the exact endpoint, secret, sender and event set are verified.
8. **No-send canary.** Enable V2 discovery/claim in a controlled test tenant with provider delivery disabled. Verify candidates, eligibility, dashboard and attribution projections without sending.
9. **Controlled delivery canary.** Only after separate explicit approval, use an owner-controlled recipient and a verified sender/domain, with a strict merchant-funded cost cap and one-store feature gate. Verify signed provider event, exact-store paid order, refund behavior and fee measurement. No real merchant customer is a test recipient.
10. **Expansion.** Expand one store/tenant at a time only after the preceding canary's evidence is reviewed and signed off. Keep a named operator watching queues, provider events, suppression, cost reservations, attribution and error rates.

## 6. Rollback and recovery semantics

Rollback is not a single database restore button. Select the response based on the stage reached:

- **Before schema change:** restore prior routing/configuration from captured exports; no data rollback required.
- **After additive schema change, before traffic:** stop V2 routing and leave additive objects in place unless a reviewed reverse migration is proven safe. Prefer a forward fix over destructive down-migration.
- **After V2 receipts or projections exist:** do not drop candidate tables or replay the same events into legacy tables. Quarantine V2 processing, preserve receipt/idempotency records and reconcile ownership before resuming.
- **After a provider request may have been accepted:** mark the attempt AMBIGUOUS, retain the cost reservation, query/reconcile provider events and do not send again until outcome is proven.
- **After orders/refunds have been projected:** preserve immutable attribution and financial audit rows; correct with idempotent compensating records, never delete or rewrite history to make dashboards balance.
- **After privacy export/redaction begins:** preserve the request deadline and completion evidence; do not restore erased personal data from an old backup without a documented legal basis and reviewed recovery procedure.
- **If a full database restore is considered:** stop all writers first, quantify data loss since backup, obtain owner approval, restore only into an isolated rehearsal first, and reconcile external provider/order events before any production resume.

At every abort: stop new V2 promotion and provider submissions; preserve durable receipts, leases, provider events, cost reservations and audit evidence; keep one authoritative event receiver; do not reactivate legacy sends until duplicate processing and in-flight outcomes are reconciled.

## 7. Go/no-go evidence record

A production go decision requires all of the following, each with a timestamp, evidence link and named approver:

- Owner-controlled Shopify app and infrastructure confirmed.
- Production parity report and historical-row disposition approved.
- Verified backup restore and production-like clone rehearsal passed.
- Migration plan, lock window, post-checks and rollback decision approved.
- Worker/Edge Function secrets and routes verified without disclosing values.
- Exactly-one ingress and exactly-one MailerSend event receiver proven.
- Three native n8n workflows reviewed, inactive-draft tested and execution retention/redaction verified.
- Manual one-off sender branch removed or safely disabled and independently verified.
- Consent, jurisdiction, suppression, merchant cap, sender and provider gates passed.
- Dashboard, order/refund attribution and fee ledger reconciled.
- Privacy export/redaction and incident response approved.
- Controlled real-store recovery test completed with signed provider event and recovered-order evidence.
- Separate explicit approval for customer sends, billing activation, Shopify release and production rollout.

Until every applicable item is evidenced, the status remains **HOLD / NOT LAUNCH-READY**.

## 8. Current known baseline (19 November 2026)

- Candidate migrations 001–058: disposable PostgreSQL CI only.
- Production Supabase: 178 migrations at last read-only inspection; no candidate V2 migration set deployed.
- V2 OAuth, privacy, webhook ingress, checkout/pixel delivery and MailerSend webhook Edge Functions: candidate branch only.
- V2 Worker: candidate source only; no production route deployment.
- n8n: three active legacy workflows; no V2 native workflow import or activation.
- Shopify app identity/ownership and owner-controlled ingress URLs: not yet fully verified.
- MailerSend V2 sender, signed event receiver and readiness flag: not production-verified.
- Real event-to-send-to-recovered-order-to-fee proof: not demonstrated.

This baseline must be refreshed read-only immediately before any future release decision.


## 9. Connected runtime refresh — 19 November 2026, read-only

The baseline above was refreshed against the connected Supabase and n8n accounts. These checks were read-only; no workflow execution, credential access, schema write, deployment or provider request occurred.

### Supabase Edge Function inventory

The live project returned 17 active Edge Functions. The following candidate V2 endpoints are **not deployed**:

- `henvalt-shopify-oauth-v2`
- `henvalt-shopify-webhook-ingress`
- `henvalt-shopify-contact-delivery-v2`
- `henvalt-shopify-pixel-delivery-v2`
- `henvalt-shopify-privacy-v2`
- `henvalt-mailersend-webhook-v2`

The live project still has the legacy `henvalt-shopify-oauth`, `henvalt-mailersend-delivery`, `henvalt-pixel-ingest-proxy`, and legacy privacy/dashboard functions. The existence of those V1 functions is not evidence that the V2 routes or V2 secret contracts are ready.

### n8n active workflow snapshot

| Workflow | ID | Active version | Nodes | Current status |
|---|---|---|---:|---|
| `HENVALT_INGEST` | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 | Active V1 |
| `HENVALT_RECOVERY` | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 | Active V1 |
| `HENVALT_DELIVERY` | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 | Active V1 |

The active Delivery graph still contains a manual-trigger one-off test-email branch with a hard-coded historical delivery request and recipient. It was inspected but **not executed**. It remains a pre-launch safety blocker until reviewed and removed/disabled through an explicitly approved change.

The current workflow-level settings expose execution order, binary mode, saved-time mode and caller policy; they do not establish instance-wide execution retention or sensitive-data redaction. That control remains unverified and must be checked in n8n instance settings before V2 cutover.

No active n8n version was changed. No fourth workflow was created. The candidate V2 Recovery/Delivery modules remain source-level adapters and build specifications, not live workflow code.

### Cutover consequence

There is no safe URL-only switch from the active V1 Recovery→Delivery payload to the V2 endpoints. V1 sends recipient, subject, body, tenant and delivery-request context; V2 accepts only an opaque checkout intervention ID or pixel opportunity ID and resolves trusted context server-side. A separately reviewed, no-send draft migration inside the existing three workflows is required before any live route change.


### Dashboard API version boundary

The live Supabase `henvalt-merchant-dashboard` Edge Function is version 4 and still calls the legacy `control_plane_dashboard_summary` and tenant-scoped `revenue_ledger` read path. The candidate repository implementation instead calls `control_plane_dashboard_summary_v2` with an exact `shopify_connection_id`, returns explicit store-selection metadata, and is designed for the new dashboard's selected-store contract.

The static `dashboard/index.html` now calls the same function slug but expects the candidate V2 response shape (`stores`, `selectedStoreId`, V2 metrics/activity). Until the candidate Edge Function is deployed after migration 041, the new dashboard page and live API are not a verified compatible pair. Do not infer dashboard launch readiness from the existing live V1 function being ACTIVE. Keep the V2 function deployment behind the schema/owner approval gate.
