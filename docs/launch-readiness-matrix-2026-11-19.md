# HENVALT launch-readiness matrix — 19 November 2026

Status: evidence-based preparation checkpoint. This matrix distinguishes committed candidate code and disposable CI tests from live production readiness. No production change was made as part of this review.

## Executive decision

**Not launch-ready yet.** The V2 recovery lifecycle is now represented by executable, offline-tested candidate code and a three-workflow native n8n build sheet. The live n8n workflows remain on the legacy implementation; V2 migrations, Edge Functions, Worker route and MailerSend event cutover have not been deployed/verified. There is no proven live Shopify event → eligible recovery → authorized email → provider event → recovered order → fee ledger end-to-end run.

## Readiness by system

| Area | Current evidence | Status | Launch requirement |
|---|---|---|---|
| Repository / PR #6 | V2 code, tests, migration sequence and docs on preparation branch; PR open/draft | Candidate | Latest-head CI green; code review; explicit merge approval |
| PostgreSQL V2 schema | Candidate migrations 001–046 apply in disposable PostgreSQL CI; claim concurrency and lifecycle tests exist | Candidate only | Review migration diff, backup/rollback plan, production apply approval, post-migration verification |
| Shopify webhook ingress | Branch Worker has V2 route to protected Edge Function; Vault-backed HMAC receipt and exact-store projections in source | Not deployed | App-specific secret registry, per-install route token provisioning, Worker/Edge secrets, one callback per topic, signed non-production tests |
| Shopify OAuth / app identity | App-aware OAuth and exact-store connection code/tests in branch | Not live-verified | Confirm app ownership/registry identity, install/reauthorize test store, callback and webhook registration |
| Recovery candidates | Checkout and pixel candidate refresh/promote/materialize/claim SQL in candidate migrations | Candidate only | Production schema applied; source events actually populating V2 tables; test candidate creation on dedicated store |
| V2 Recovery orchestration | Offline-tested Recovery orchestrator, bounded service RPC client, lease finisher and Delivery subworkflow contract | Candidate only | Build/verify native nodes inside existing HENVALT_RECOVERY; unique execution worker IDs; execution-data privacy controls |
| V2 Delivery | Offline-tested checkout/pixel routing adapter; Edge Functions accept opaque IDs and own rendering/authorization/provider call | Candidate only | Build/verify native nodes inside existing HENVALT_DELIVERY; independent auth, sender profile, consent and cost preflight |
| Live n8n | Three active legacy workflows unchanged: Ingest 51 nodes, Recovery 46 nodes, Delivery 62 nodes | Blocked | Controlled in-place cutover; eliminate legacy/V2 duplicate sends; remove historical manual one-off sender branch |
| MailerSend | V2 webhook Edge Function and signed raw-body verification code/tests in branch; live legacy n8n receiver remains | Blocked | Verified sender domain; V2 webhook URL/signature test; exactly one event receiver; readiness gate configured |
| Dashboard | Candidate read model and dashboard Edge Functions in branch | Not live-verified | Deploy after schema; authenticate exact-store merchant; verify live metrics, attribution and sign-out clearing |
| Attribution / performance fee | Candidate order/refund attribution and billing measurement migrations/tests | Not live-verified | Real test order, refund reversal, fee calculation and ledger reconciliation against a test store |
| Privacy / execution logs | Database privacy/export/redaction lifecycle has extensive disposable tests; n8n retention/redaction settings not verified | Blocked | Verify instance retention/redaction; minimize successful/failed execution payloads; prove no customer/provider secrets in logs |
| End-to-end proof | Offline fake-fetch tests; no real provider network escape; no live V2 send or recovery attribution verified | Blocked | Dedicated test store that can complete an order; no-send tests first; controlled provider test only after explicit approval |

## Verified live n8n snapshot

The active versions have not changed during this work:

- `HENVALT_INGEST` — `VTpfGKNtu1CSQ4Rv`, active version `6368d539-708f-494a-8be8-b9601d0e8607`. It still includes legacy checkout opportunity/recovery sequence/intervention creation.
- `HENVALT_RECOVERY` — `3GEDoeCA4paXTaDF`, active version `32e50bf7-4cbd-4070-bbba-f259ed17b369`. It still runs legacy job/intervention claims, AI copy, message/token creation and legacy delivery handoff.
- `HENVALT_DELIVERY` — `CvVyybGJZSnklxiZ`, active version `621ae6ce-a006-4fed-a70e-acf774c360fb`. It still owns legacy sending and MailerSend event processing. Its manual one-off send branch contains a hard-coded historical delivery request and recipient. It was not executed or modified.

No V2 Recovery schedule or V2 Delivery subworkflow has been imported or activated. No fourth workflow was created.

## Critical safety rules

1. Do not run V2 and legacy recovery for the same store/topic concurrently. Legacy Ingest creates old recovery records while V2 has separate exact-store candidate tables.
2. Do not change the legacy Delivery URL to a V2 Edge Function. The payload contracts are incompatible.
3. For V2 claims, n8n receives only `lease_id`, `work_type`, and `work_id` from SQL; Recovery passes only five fields to Delivery. Recipient, subject, HTML/text, Shopify tokens and MailerSend credentials stay outside n8n item data.
4. A V2 202 response with `accepted:true` and ambiguous/pending status is `HANDOFF_ACCEPTED`; the Edge Function owns reconciliation and Recovery completes the lease. Do not re-submit.
5. A request timeout may be deferred; the Edge Function's attempt guard and claim query prevent a second send when an attempt already exists.
6. MailerSend events must be processed by exactly one receiver. V2 requires original raw body and signature sent directly to the V2 Edge Function.
7. The manual one-off test sender branch in live Delivery must be reviewed and disabled/removed before launch.
8. Do not infer successful production state from CI. CI runs against disposable PostgreSQL and fake provider responses.

## Controlled launch sequence

1. **Finish code validation:** latest PR-head Node suite, Gitleaks, Deno checks, disposable migration application and SQL concurrency/lifecycle tests all green.
2. **Review and merge:** code review and explicit merge approval; do not auto-merge.
3. **Prepare production database:** verify migration history and current schema; backup; review every candidate migration; apply only after explicit production approval; run post-migration read-only checks.
4. **Provision identity/secrets:** verify Shopify app identity and Vault secret references; provision per-connection route tokens; configure Worker↔Edge auth and delivery bearer secrets without exposing values.
5. **Prove ingress:** non-production valid/invalid HMAC, wrong-store, duplicate webhook, inactive app and replay tests; confirm exact-store checkout, consent, order and refund projections.
6. **Configure provider:** verified sender domain with HTML/plain unsubscribe insertion; V2 MailerSend signed event URL and raw-body signature tests; one receiver only.
7. **Build the existing three workflows:** use the native build sheet to update Recovery and Delivery in-place; preserve Ingest for explicitly retained legacy/internal topics; remove the one-off sender branch; verify retention/redaction.
8. **Prove no-send first:** wrong store, inactive tenant/store, closed/converted order, missing consent, unsubscribe/suppression, sender/domain failure, cost cap, stale lease, timeout and ambiguous response all behave safely with provider fetch stubbed.
9. **Run controlled store test:** dedicated store with real order capability; verify event → opportunity → claim → Delivery → provider event → order attribution → refund adjustment → fee measurement. Do not send to real customers.
10. **Enable merchants only after evidence:** verify dashboard tenant/store scoping, uninstall stop, provider event dedupe, billing state and support/incident controls.

## Current production-change boundary

No production Supabase migration, Edge Function deployment, Cloudflare Worker deployment, Shopify app release, Shopify webhook re-registration, n8n workflow edit/activation, MailerSend configuration change, customer email or billing charge was performed in this batch.
