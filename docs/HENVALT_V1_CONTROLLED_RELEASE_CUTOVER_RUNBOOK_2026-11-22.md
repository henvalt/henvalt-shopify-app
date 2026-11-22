# HENVALT V1 controlled release and cutover runbook — 2026-11-22

**State: candidate-only operating procedure. NO PRODUCTION CUTOVER IS AUTHORIZED BY THIS DOCUMENT.**  
**Current release decision: NO-GO.** The candidate has substantial disposable-CI evidence, but no isolated Supabase staging environment has been verified and the end-to-end gates below remain open.

## 1. Release invariants

1. Production project identity is `ocyplckdojdubyrsxcxa`; staging must have a different project ID and separate credentials.
2. Keep exactly the three existing n8n workflows: `HENVALT_INGEST`, `HENVALT_RECOVERY`, and `HENVALT_DELIVERY`. Do not create a fourth workflow.
3. The candidate global provider-send interlock remains closed during all installation, migration, replay, consent, privacy, dashboard, and billing validation.
4. No live MailerSend token or real recipient may exist in the staging test environment. Use a provider stub or enforce network-denied egress.
5. A green disposable PostgreSQL suite is necessary but is not proof of live Supabase Vault, RLS, Edge Function, n8n, Shopify, or provider integration.
6. No production migration, function deployment, workflow publication, Shopify app release, billing mutation, or customer message occurs without a separately explicit production authorization.

## 2. Freeze the release candidate (Gate A)

Record one immutable release manifest before staging work:

- Git repository and PR: `henvalt/henvalt-shopify-app`, PR #7.
- Candidate branch: `work/48h-system-readiness-2026-11-21`.
- Exact commit SHA (never use a moving branch name as the test identity).
- Full ordered migration filename list and SHA-256 for each file.
- Edge Function source hashes, function slugs, gateway JWT mode, and required environment-variable *names* (never values).
- n8n workflow IDs, active version IDs, sanitized export hashes, active state, and credential references.
- Shopify app client identity, dev-store domain, requested scopes, webhook topic list, and app configuration hash.
- Cloudflare Worker script hash, route/domain, and upstream target.
- CI workflow run IDs and results; staging execution IDs and evidence links.
- Test operator, timestamp, and explicit confirmation that all provider egress is denied.

Stop if any tested source hash differs from the candidate manifest. A new commit invalidates the previous staging sign-off for changed components.

## 3. Provision and isolate staging (Gate B)

1. Obtain an explicitly approved, cost-reviewed isolated Supabase staging project. Do not create a paid branch or project silently.
2. Confirm its project ID differs from production and that its region, Postgres version, extensions, roles, RLS, Vault, cron, and Edge Function settings are recorded.
3. Use a separate n8n staging workspace or isolated workflow copies with distinct IDs and credentials. Never edit the three production workflow IDs during staging.
4. Use a Shopify development store and a staging-only app/configuration. Confirm OAuth callback, webhook destination, pixel collector, and dashboard URLs all point to staging.
5. Remove production MailerSend credentials from staging. Network-deny outbound email and Shopify billing mutations except where a specific synthetic dev-store test is explicitly approved.
6. Prove cross-environment isolation by attempting to use staging credentials against production endpoints and production credentials against staging; both must fail.
7. Capture a baseline: migration history, functions, cron jobs, RLS/ACLs, active workflow versions, webhook registrations, queue counts, and send-interlock state.

**Gate B fails** if a production secret is copied into staging, if any staging route resolves to a production database or workflow, or if provider egress cannot be demonstrated blocked.

## 4. Database migration sequence (Gate C)

Run the exact reviewed candidate migration set in ascending order on the isolated staging database. Apply each migration once, record its result, and stop on the first error. Do not run an unrestricted `supabase db push` against the mixed candidate branch.

1. `202611210001_provider_send_interlock_v1.sql`
2. `202611210002_pixel_consent_and_marketing_gate.sql`
3. `202611210003_dashboard_confirmed_revenue_metrics.sql`
4. `202611210004_align_shopify_token_refresh_window.sql`
5. `202611210005_shopify_webhook_replay_enqueue.sql`
6. `202611210006_shopify_webhook_replay_load.sql`
7. `202611210007_shopify_webhook_single_roundtrip_ingress.sql`
8. `202611210008_shopify_replay_lease_fencing.sql`
9. `202611210009_shopify_replay_business_write_fencing.sql`
10. `202611210010_shopify_replay_complete_ingest_write_fencing.sql`
11. `202611210011_shopify_replay_write_lease_heartbeat.sql`
12. `202611210012_shopify_privacy_tenant_fk_index.sql`
13. `202611220001_shopify_privacy_claim_and_minimization.sql`
14. `202611220002_shopify_privacy_redaction_guards.sql`
15. `202611220003_shopify_privacy_retention_cron.sql`
16. `202611220004_shopify_privacy_signed_payload_idempotency.sql`
17. `202611220005_shopify_privacy_queue_worker.sql`
18. `202611220006_shopify_privacy_export_acknowledgement.sql`
19. `202611220007_shopify_replay_tenant_binding.sql`
20. `202611220008_shopify_replay_object_tenant_binding.sql`
21. `202611220009_mailersend_delivery_envelope_binding.sql`
22. `202611220010_promote_confirmed_recovery_ledger.sql`
23. `202611220011_billing_refund_credit_offsets.sql`
24. `202611220012_dashboard_net_revenue_series.sql`
25. `202611220013_shopify_order_edit_revenue_reconciliation.sql`
26. `202611220014_billing_result_lock_order_and_monotonicity.sql`
27. `202611220015_billing_claim_subscription_lock.sql`
28. `202611220016_billing_deterministic_failure_reconciliation.sql`

After each migration, verify its expected objects, grants, constraints, indexes, and idempotency. After the sequence, verify:

- `anon` and `authenticated` cannot execute service-only ingestion, replay, provider-token, billing claim/result, or operator RPCs.
- RLS and tenant-bound checks deny cross-tenant reads and writes.
- The global send interlock defaults closed and cannot be changed by application roles.
- Privacy cron/queue schedules have exactly the expected cadence and command, with no duplicate active job.
- Replay jobs and privacy jobs have bounded leases, retry limits, dead-letter behavior, and tenant binding.
- Billing result transitions remain monotonic; cancelled/suspended subscriptions cannot create a new claim; exhausted deterministic failures become operator-visible reconciliation items.
- Revenue ledger adjustments are idempotent and net revenue includes refunds, cancellations, and downward order edits.
- No migration has inserted or altered production data (staging data only).

Do not manually skip a migration because its feature appears unused. If a migration fails, preserve the failed staging evidence, correct the candidate, create a new commit, and rerun from a clean disposable/staging database.

## 5. Edge Function and secret rollout (Gate D)

Deploy only reviewed function slugs, never a blanket deploy-all operation. Apply schema first, then deploy functions that depend on it.

Candidate function inventory to verify against the exact commit before deployment:

- `henvalt-shopify-oauth`
- `henvalt-merchant-dashboard`
- `henvalt-mailersend-setup`
- `henvalt-mailersend-delivery`
- `henvalt-shopify-privacy`
- `henvalt-privacy-export`
- `henvalt-shopify-usage-billing`
- `henvalt-billing-reconciliation`

For every function, record gateway `verify_jwt` mode and the handler's own authentication contract. In particular:

- Shopify HMAC endpoints must verify the exact raw request body themselves; gateway JWT must not bypass or replace Shopify HMAC validation.
- Worker-token endpoints may disable gateway JWT only when a dedicated, high-entropy worker bearer token is configured and compared safely by the handler.
- Owner/admin dashboard and reconciliation routes must validate Supabase identity and tenant membership server-side.
- Never expose service-role keys or provider secrets to browser code, n8n execution payloads, logs, or dashboard responses.
- Configure secret names from the source contract, validate presence without printing values, and rotate staging credentials independently.

For the candidate `henvalt-shopify-oauth`, record and validate these exact environment-variable **names** in the isolated staging function before deployment:
- `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET`, `SHOPIFY_REDIRECT_URI`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- `SHOPIFY_WEBHOOK_INGRESS_BASE_URL` — required HTTPS origin; candidate appends `/shopify/webhooks`
- `SHOPIFY_PIXEL_COLLECTOR_URL` — required HTTPS URL with exact path `/v1/events`
- `HENVALT_DASHBOARD_URL` — optional override; candidate default is `https://henvalt-dashboard.pages.dev`
- `SHOPIFY_SCOPES` — optional override; required scopes are appended by the handler

The candidate OAuth handler deliberately returns configuration-unavailable when either Worker URL is absent or invalid. Do not copy the old hard-coded Worker origins from deployed v27; verify the new staging Worker endpoints and bind them explicitly.
- Do not deploy the legacy `henvalt-control-plane` from the candidate branch: its deployed source is not present in this repository and its legacy billing routes require separate review.

Run Deno type checks and authenticated/unauthenticated handler tests after each function deploy. Record deployed function version identifiers and test request IDs.

## 6. Existing n8n workflow integration (Gate E)

Preserve the three-workflow topology and use the candidate builders/specifications as reviewed inputs:

- `HENVALT_INGEST`: verify Shopify HMAC and delivery identity; durably enqueue the replay job before returning a success acknowledgement; use Shopify webhook delivery ID as the idempotency key and event ID only as correlation metadata. Every branch must return an explicit status. Invalid signature is 401; verifier/Vault outage and ambiguous persistence are retryable 503; duplicate 200 requires durable evidence.
- `HENVALT_RECOVERY`: route existing intervention jobs through the existing path; route `process_shopify_webhook` jobs through the worker-bound replay loader and persisted-event processor. Every mutating stage must validate the current lease/tenant/source event at the database write boundary. Renew leases before long stages; stop work on lost lease. Add billing scheduler work to this workflow only after isolated tests, with bounded claims and a dedicated worker token.
- `HENVALT_DELIVERY`: retain normal and manual delivery routes, but both must pass the same database interlock, consent/suppression, tenant-envelope, and provider-token checks. No alternate manual route may bypass the global gate.

Before changing any workflow, export and hash the current active version. Build and validate the candidate graph in the isolated n8n environment. Do not activate or publish candidate changes in production as part of this gate.

Required tests: valid/invalid HMAC; duplicate and conflicting delivery IDs; durable enqueue; replay after worker crash; stale lease rejection at each write boundary; tenant mismatch; processed duplicate no-op; retry/dead-letter; normal and manual delivery denied while interlock closed; zero provider token release and zero provider network calls.

## 7. Shopify app and storefront verification (Gate F)

1. Validate TOML and Shopify CLI app configuration against the staging domains.
2. Complete OAuth with a staging development store; reject invalid, expired, and replayed state; verify exact shop/tenant binding and minimal scopes.
3. Register required order, checkout, uninstall, and compliance webhooks; persist and verify provider webhook IDs.
4. Deliver signed synthetic webhook payloads and confirm durable acknowledgement only after atomic raw-ingest plus replay-job persistence.
5. Exercise uninstall and token refresh; verify connection deactivation, send denial, token-pair rotation, and safe retry on persistence failure.
6. Validate the pixel extension and consent gates on a staging storefront. Analytics denial must prevent identity-bearing analytics persistence; marketing denial must prevent email recovery.
7. Test consent revocation after an opportunity exists; authorization and provider-token claim must independently deny delivery.
8. Verify the app dashboard URL, callback URL, webhook URL, and pixel collector all resolve to staging, not the production Pages or Supabase endpoints.

No public Shopify app release or production app configuration change is part of this gate.

## 8. Privacy, revenue, and billing acceptance (Gate G)

- Execute Shopify customer-data request, customer-redact, and shop-redact with synthetic data; verify signed payload idempotency, tenant/store scoping, redaction, queue retry, retention expiry, and audit evidence.
- Verify privacy export body is fully received before the authenticated client acknowledgement is accepted; test expiry and replay of acknowledgement tokens.
- Verify execution logs and retained n8n payloads do not expose tokens, full email bodies, or unnecessary customer data. If instance-level pruning is not inspectable, record it as an unresolved blocker rather than assuming it is enabled.
- Confirm an order creates billable recovered revenue only after attribution is confirmed. Test probable-to-confirmed promotion in place, refund/cancel credits, partial/full credit allocation, order edits, and replay idempotency.
- Verify a cancelled subscription blocks claims. Test concurrent claim/cancel and exhausted FAILED/PENDING deterministic rejection reconciliation.
- Keep all Shopify usage mutations stubbed unless a separate synthetic development-store usage-record test has been explicitly approved. Reconcile provider record ID, charge ID, amount, currency, measurement, and ledger exactly.

## 9. End-to-end release rehearsal (Gate H)

Run one synthetic lifecycle with provider egress denied:

1. Install the app on the staging store.
2. Deliver a signed checkout/cart event with analytics/marketing consent state explicitly set.
3. Confirm one tenant-bound canonical event, one eligible opportunity, and one recovery job.
4. Advance the scheduler and confirm one intervention claim with lease ownership.
5. Confirm delivery authorization is denied while the interlock is closed and no provider token is released.
6. Open the interlock only in isolated staging, still using a provider stub; prove one stub request and idempotent duplicate suppression.
7. Deliver a paid order before a second send; confirm suppression wins.
8. Confirm order attribution, revenue ledger, dashboard activity, refund/order-edit adjustment, and billing measurement reconcile.
9. Exercise uninstall, unsubscribe, privacy request, and billing cancellation; confirm no later recovery or billing claim is possible.
10. Re-run duplicate webhooks and worker retries; confirm no duplicate opportunity, message, recovered-revenue row, credit, or Shopify usage record.

Capture database rows by opaque IDs, n8n execution IDs, function logs with sensitive fields redacted, Shopify delivery IDs, and dashboard screenshots. Do not use real customer data.

## 10. Go/no-go, production approval, and rollback (Gate I)

**NO-GO** if any of the following is true:

- Staging is not demonstrably isolated or cost approval is missing.
- Exact source/version hashes are not recorded.
- Any migration, RLS, ACL, tenant-binding, replay fencing, or consent test fails.
- Any provider call or token release occurs while the interlock is closed.
- Any Shopify webhook can receive 2xx without durable acceptance.
- Any replay worker can mutate data after lease loss or across tenants.
- Any recovery amount is counted without confirmed attribution or refund/order-edit adjustments.
- Any billing charge can be duplicated, silently abandoned, or created after cancellation.
- Any privacy request remains unprocessed without an explicit, owner-visible exception path.
- n8n execution retention, provider emergency revocation, or legacy billing route exposure remains unreviewed.

Production cutover requires a new, explicit approval identifying the exact commit, migration list, function list, workflow version IDs, Shopify app version, time window, rollback owner, and whether any live provider or billing action is permitted. Approval to test staging is not approval for production.

Rollback must be forward-safe: stop new claims/schedules first, preserve webhook/privacy/billing receipts, leases, idempotency keys, audit rows, and financial ledger history, and restore only previously verified function/workflow versions. Do not drop columns or delete queue/audit/financial history to imitate rollback. If a worker is stopped, do not acknowledge new webhooks successfully unless a durable alternate processor remains available.

## 11. Fresh production baseline captured 2026-11-22 (read-only)

The following snapshot was rechecked against the connected production Supabase project and the active n8n workflow versions after this runbook was drafted. It is evidence of the live baseline, not permission to change it.

### Supabase production

- Project: `ocyplckdojdubyrsxcxa`; Postgres 17.6.1.
- Latest applied migration: `20261114174204`. Candidate migrations listed in Gate C are not applied.
- `henvalt-control-plane`: ACTIVE version 24, gateway `verify_jwt=false`.
- `henvalt-shopify-oauth`: ACTIVE version 27.
- `henvalt-merchant-dashboard`: ACTIVE version 4.
- `henvalt-mailersend-setup`: ACTIVE version 8.
- `henvalt-mailersend-delivery`: ACTIVE version 1.
- `henvalt-shopify-privacy`: ACTIVE version 1.
- `henvalt-privacy-export`: ACTIVE version 1.
- `henvalt-shopify-usage-billing` and `henvalt-billing-reconciliation`: absent from the production Edge Function inventory at this inspection.

The two privacy functions already present in production are older deployed versions; their presence does not mean the candidate privacy queue/acknowledgement implementation has been deployed. Compare the deployed function hashes and candidate source before any replacement.

### Legacy control-plane billing route — precise authentication and mutation boundary

Read-only source retrieval of deployed `henvalt-control-plane` v24 confirms:

- The Supabase gateway has `verify_jwt=false`, but the handler requires a Bearer token and calls service-only `henvalt.control_plane_verify_api_token` before route dispatch.
- That verifier reads the Vault secret named `HENVALT_CONTROL_PLANE_TOKEN`, rejects candidates outside 32–512 characters, and compares SHA-256 digests. The Edge Function then requires a valid `x-henvalt-shop` header.
- The old `POST /v1/billing/usage/claim` and `POST /v1/billing/usage/result` routes are present. They call the production `control_plane_claim_billing_usage` and `control_plane_record_billing_usage_result` RPCs.
- The inspected production RPC definitions are older than the candidate lock-order/monotonicity/reconciliation migrations. In particular, the old result RPC updates charge state to SUBMITTED or FAILED without the candidate monotonic transition protections. A late failure can therefore overwrite a previously submitted state if this legacy route is invoked.
- The old claim RPC selects an active connection with `LIMIT 1` and does not implement the candidate exact-one-active-shop, tenant/shop row-lock, subscription-row-lock, or exhausted deterministic reconciliation behavior.
- Database ACL inspection shows these legacy billing RPCs execute only for `service_role`; application roles do not receive direct execution. This reduces direct client exposure but does not remove the old authenticated Edge Function route.
- The three active n8n workflows were inspected and do not call these legacy billing routes. The candidate billing worker is a separate design and is not deployed.

**Required disposition before merchant-facing billing:** recover/version-control the exact deployed control-plane source; map every caller of the two legacy routes; prove no active client or workflow depends on them; then remove or hard-disable the legacy billing routes in a separately reviewed release. Do not replace the entire production function from the candidate branch merely to remove these routes. Do not rotate the shared Vault token until every dependent control-plane caller has been inventoried and migrated.

### Active n8n production versions

| Workflow | Workflow ID | Active version ID | Nodes | State |
|---|---|---|---:|---|
| `HENVALT_INGEST` | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 | Active |
| `HENVALT_RECOVERY` | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 | Active |
| `HENVALT_DELIVERY` | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 | Active |

The live ingest graph still needs an explicit Respond to Webhook path and durable replay-job acknowledgement before a 2xx can be considered safe. The live recovery graph still has its intervention-job claim/guard and does not yet implement the candidate `process_shopify_webhook` replay-job router. The live delivery graph retains both normal and manual send entry paths; both require isolated egress-denied validation against the same interlock before release. These are not candidate deployment claims.

## 12. Current known blockers at authoring time

- No isolated Supabase staging project/branch has been verified; do not incur cost by creating one without approval.
- Production migration history remains behind candidate migrations 001–016; none of these migrations has been applied to production.
- Candidate billing worker and reconciliation functions are not deployed; no live billing usage charge has been tested.
- Production's legacy control-plane billing routes remain present behind a global control-plane token; they are not called by the three active workflows, but require source recovery and security review before merchant-facing billing.
- The three production n8n workflows are active and have not been changed by this candidate.
- The latest candidate CI evidence is a successful full safety run on the exact PR head recorded in PR #7; recheck exact-head CI after any new commit.
- Provider-send interlock, privacy queue, replay worker, and billing changes are candidate-only until staging evidence and a separate production authorization exist.

**Final rule:** no amount of CI success, batch count, or elapsed time substitutes for an evidenced end-to-end staging pass and an explicit production go decision.
