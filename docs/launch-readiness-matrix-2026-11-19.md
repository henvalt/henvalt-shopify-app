# HENVALT launch-readiness matrix — 19 November 2026

Status: evidence-based preparation checkpoint. This matrix distinguishes committed candidate code and disposable CI tests from live production readiness. No production change was made as part of this review.

## Executive decision

**Not launch-ready yet.** The V2 recovery lifecycle is now represented by executable, offline-tested candidate code and a three-workflow native n8n build sheet. The live n8n workflows remain on the legacy implementation; V2 migrations, Edge Functions, Worker route and MailerSend event cutover have not been deployed/verified. There is no proven live Shopify event → eligible recovery → authorized email → provider event → recovered order → fee ledger end-to-end run.

## 19 November — checkout candidate terminal-state and lease retry hardening

The candidate chain now includes migration 058 (`202611190004_shopify_checkout_candidate_terminal_state_v2.sql`). Checkout candidate refresh preserves `CONVERTED` and `CHECKOUT_CLOSED` states rather than re-queueing closed work. SQL regression coverage proves a closed candidate is not resurrected by a contradictory later open projection, while a matching same-store order can still convert it. The lease lifecycle test also verifies deferred work cannot be reclaimed before its retry deadline and receives a fresh lease identity after becoming due.

Exact-head CI at `975d293b77dc050292b41efa4cba53b1bd5659dd` passed the complete Node suite, secret scan, Deno checks, disposable migration application, checkout eligibility, parallel merchant-wide cost cap, concurrent recovery claims and pixel outcome/attribution/cost lifecycle tests. The Shopify configuration workflow's static and database validation passed; the Shopify deploy job was skipped. This remains candidate-only validation, not production readiness.

## 19 November — owner-controlled Worker endpoint hardening

A source review found the OAuth V2 callback still hard-coded two Worker URLs
under a former collaborator's `workers.dev` namespace: the per-install
Shopify webhook ingress and the storefront pixel collector. These are not
acceptable as assumed production dependencies.

The candidate now reads `SHOPIFY_WEBHOOK_INGRESS_BASE_URL` and
`SHOPIFY_PIXEL_COLLECTOR_URL` from server-side runtime configuration, validates
HTTPS/origin/path shape, and fails closed when either is missing or malformed.
The callback builds its per-install webhook URI from the configured ingress
origin; the Shopify pixel receives only the configured collector URL. A new
offline regression test prevents the former collaborator hostname from
returning.

This removes the hard-coded dependency from candidate source; it does not
prove that owner-controlled Worker routes or runtime secrets exist. Both
endpoints must be provisioned and tested before OAuth V2 can report configured
or accept an install. No Worker or Edge Function was deployed and no Shopify
subscription was changed.


## 19 November — read-only production Supabase verification

A fresh read-only inspection of the connected Supabase project `ocyplckdojdubyrsxcxa` confirms the V2 candidate is **not deployed**:

- Project reports `ACTIVE_HEALTHY`, PostgreSQL 17.6.1.
- The production migration history contains 178 migrations and currently ends at `20261114174204` (`fix_mailersend_token_browse_case_expression`). No V2 app-identity/webhook/privacy/recovery migration versions dated 16–19 November are present.
- The live `henvalt` schema has no V2 app registry, per-install webhook route-token table, V2 privacy inbox table, or V2 recovery claim/candidate tables.
- The live Edge Function inventory contains 17 functions; the V2 OAuth, privacy, webhook-ingress, checkout-delivery, pixel-delivery and MailerSend webhook functions are not deployed. Existing dashboard functions are present.
- The existing legacy schema and live n8n workflows therefore remain the production path. Candidate migration tests passing in GitHub Actions must not be interpreted as production schema readiness.

This is a read-only verification. No SQL write, migration, function deployment, secret read/change, webhook registration, workflow edit or customer send was performed. The production project remains untouched.

## 19 November — bounded webhook ingress and acknowledgement

The candidate V2 webhook path now applies explicit bounds in both directions:

- Cloudflare Worker reads Shopify request bytes incrementally and rejects bodies above 1,000,000 bytes before forwarding.
- The Supabase ingress Edge Function uses the shared streaming reader with the same 1,000,000-byte ceiling before base64 encoding and invoking the verified inbox RPC.
- Worker-to-Edge acknowledgement JSON is read incrementally with a 16 KiB ceiling. Missing, malformed or oversized responses fail closed with 503; only a JSON object with `accepted: true` is acknowledged to Shopify.
- Edge-to-PostgREST RPC responses are read incrementally with a 32 KiB ceiling. The RPC request has an 8-second abort deadline; malformed/oversized responses fail closed rather than being interpreted as a receipt.
- Regression tests cover oversized inbound request bodies, rejected upstream destinations, oversized acknowledgement responses, finite RPC deadlines and the durable-acceptance gate.

These are candidate source and offline CI protections only. They do not establish production latency, Shopify retry behavior, deployed Worker/Edge configuration or durable production receipt availability. The legacy webhook route remains separately wired and unchanged pending an approved cutover.

## Readiness by system

| Area | Current evidence | Status | Launch requirement |
|---|---|---|---|
| Repository / PR #6 | V2 code, tests, migration sequence and docs on preparation branch; PR open/draft | Candidate | Latest-head CI green; code review; explicit merge approval |
| PostgreSQL V2 schema | Candidate migrations 001–060 apply in disposable PostgreSQL CI; checkout terminal-state preservation, final provider-submission authorization, deferred retry deadlines, claim concurrency and lifecycle tests pass | Candidate only | Review migration diff, backup/rollback plan, production apply approval, post-migration verification |
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


## 19 November — live Supabase advisor review (read-only)

The live project advisor scan returned:

- **Security:** 11 tables have RLS enabled and no policies. These are internal/service-role tables (billing, provider usage, pixel keys/rate limits, OAuth state, privacy request queue, etc.); absent policies means normal client roles are denied by default. Do not add broad policies just to silence this advisory.
- **Security:** `henvalt.is_tenant_member(uuid)` is SECURITY DEFINER and executable by `authenticated`. Inspection confirms it is the predicate used by the existing tenant-isolation policies across core tenant tables. This is a deliberate RLS helper pattern, but because the `henvalt` schema is used through PostgREST, the function's direct RPC exposure should be explicitly reviewed for tenant-membership enumeration. Do not revoke it blindly: doing so would break the policies that call it.
- **Auth:** leaked-password protection is disabled. Enable Supabase Auth's leaked-password protection in project Auth security settings before public merchant onboarding.
- **Performance:** one existing foreign key, `shopify_privacy_requests.tenant_id`, lacks a covering index. Add a reviewed index migration before material privacy-request volume; do not change production schema during this preparation session. The 72 unused-index notices are not a reason to delete indexes before the workload has meaningful traffic.
- **Health:** no advisor health lints were returned.

No production configuration or schema was changed. These findings are added to the launch checklist rather than silently patched in production.

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


## 19 November — OAuth callback route alignment

The candidate `shopify.app.toml` OAuth redirect now targets `henvalt-shopify-oauth-v2/callback`, matching the app-aware OAuth Edge Function and per-install route-token provisioning path. A Node regression test checks this configuration-to-function alignment. The Shopify static/configuration workflow passed on the TOML/test commit; full exact-head validation for the subsequent documentation-only commit is running.

This does **not** verify the deployed `SHOPIFY_REDIRECT_URI` secret or release the app configuration. The candidate compliance webhook now targets the stable V2 privacy Edge Function URL. V2 resolves the active app key from the trusted app registry using the configured Shopify client ID, instead of requiring a guessed key in the URL. This removes the path-key configuration blocker in candidate source, but the production registry row/Vault secret, deployed Edge Function, and signed Shopify compliance receipt are still unverified production gates.


## 19 November — app-registry-bound Shopify privacy route

The candidate Shopify TOML now routes mandatory compliance topics to `henvalt-shopify-privacy-v2`. That Edge Function resolves the active app identity from the trusted registry with the configured Shopify client ID and fails closed if the registry/Vault-backed secret is unavailable. It no longer trusts a URL path segment to select the app key. The privacy SQL RPC continues to verify the raw request body HMAC and exact app/store connection. This is candidate code only; no production registry row, Vault secret, deployment or webhook receipt has been verified.


## 19 November — exact OAuth redirect secret gate

OAuth V2 now validates `SHOPIFY_REDIRECT_URI` as the exact HTTPS callback path `/functions/v1/henvalt-shopify-oauth-v2/callback` on the same Supabase project origin. A non-empty but mismatched secret no longer passes the OAuth configuration gate. Added a regression test and included both infrastructure-endpoint and callback-alignment tests in Shopify static validation. The deployed secret value remains unverified; no secret was read or changed.


## 19 November — Shopify callback gateway authentication configuration

A source review found the candidate Supabase config did not explicitly disable gateway JWT for the three browser/Shopify callback endpoints. Supabase's default gateway JWT would reject Shopify's unauthenticated redirect/webhook requests before the handlers could perform their own protocol authentication. Added explicit `verify_jwt = false` only for OAuth V2, privacy V2 and webhook ingress. Their handlers continue to validate merchant sessions, OAuth state/HMAC, app-specific privacy HMAC, and Worker bearer + Shopify HMAC respectively. A regression test asserts the exact three entries and the OAuth handler's merchant authentication. This config change is candidate-only and has not been deployed.


## 19 November — dashboard V2 store eligibility and revenue visualization

- The dashboard's Shopify connection action now targets the V2 OAuth install route; it no longer starts the legacy OAuth flow.
- The V2 merchant dashboard API now lists only active connections whose app key belongs to an active app-registry entry and which have Shopify shop ID, access-token and refresh-token secret references, and no outstanding reauthorization requirement. Legacy rows marked active but missing V2 lineage are not offered as V2 stores.
- The dashboard clears metrics and store identity on account changes, store changes, missing V2 connection, and failed requests. This prevents a previous store's metrics or label from remaining visible after a scope transition.
- Migration 041 now returns a daily UTC series built only from positive, CONFIRMED exact-connection recovered-order attribution. The chart no longer derives revenue from individual recent activity rows. Mixed-currency totals are not combined.
- Added regression coverage for the dashboard OAuth route, exact-store V2 eligibility, stale-data clearing, and server-aggregated daily revenue series.
- Exact PR head `feee38f47422f88421ce43de3f89d242db81feb6`: full repository Node suite **412/412 passed**, focused identity/cost/privacy suite **213/213 passed**, Shopify static/configuration checks passed, disposable PostgreSQL migration validation passed, and app deployment was skipped. This is candidate CI evidence only; no live dashboard Edge Function or migration was deployed.
- Important compatibility gate: the live `henvalt-merchant-dashboard` Edge Function is still V1 and does not return the V2 store-selection/revenue-series contract. The dashboard UI and V2 API are not a production-compatible pair until migration 041 and the candidate Edge Function are deployed together under approved cutover.


## 19 November — dashboard request authentication and n8n batch acknowledgement verified

- Direct browser fetch calls to the dashboard, OAuth install and MailerSend setup Edge Functions now send the publishable project key on the apikey header and the signed-in user's session JWT on Authorization. OAuth and MailerSend setup CORS allow the apikey header. This follows Supabase's current documented distinction between API-key identification and user authentication.
- n8n's per-item finish-acknowledgement snippet now reads the current response through $input.item.json; it no longer reads the first response for every item in a multi-claim batch. Regression tests cover distinct acknowledgements and two independent claimed work items.
- Dashboard stale-store recovery now clears a removed selection and reloads the eligible store list. A regression test covers the 404 store_not_available path.
- Exact candidate head 38b86861bed1bc986be6b815aa42fa2f3f4f4b4b: full repository Node suite **414/414 passed**; focused identity/cost/privacy contracts **214/214 passed**; Gitleaks passed; Deno Edge Function type checks passed; all 58 candidate migrations applied to disposable PostgreSQL and the exact-store, privacy, cost-reservation and concurrency SQL suites passed. Shopify static/configuration and disposable migration validation passed; Shopify deployment was skipped.
- This is CI evidence for candidate code only. PR #6 remains open, draft and unmerged; no production database, Edge Function, Worker, Shopify release, active n8n workflow, MailerSend configuration or customer send was changed.

## 19 November — seeded dashboard read-model integration verified

- Added a disposable PostgreSQL integration test for the V2 dashboard read model after candidate migrations 001–058 and the synthetic two-store webhook fixture.
- The test invokes the actual `control_plane_dashboard_summary_v2` function against an active synthetic store and verifies zero-safe metrics, all three inclusive UTC daily buckets, zero daily amounts, and the inactive-store fail-closed response.
- The test also verifies the 366-day range guard and confirms the RPC is executable by `service_role` only.
- Added the SQL test to the identity V2 GitHub Actions migration pipeline and a Node regression test that guards the CI wiring and exact-store/confirmed-attribution contract.
- **Exact candidate head `b315f19ceb686eedcf5817d56db49b116806ab1d` passed:** full Node suite **417/417**, focused identity/cost/privacy contracts **214/214**, Gitleaks, Deno Edge Function type checks, migrations 001–058, and the seeded dashboard SQL integration (`shopify_v2_dashboard_read_model_passed`). The final SQL assertions also verify the three zero-valued event categories and empty activity list. Shopify static/configuration and disposable migration validation passed; the Shopify deployment job was skipped.
- This validates the empty/zero-data read-model path, inclusive UTC date buckets, inactive connection behavior and RPC privileges in disposable PostgreSQL. The existing pixel delivery lifecycle SQL integration also exercises a populated recovery/send/order/attribution graph against this same dashboard RPC: it verifies one confirmed USD 125.50 recovered order, isolation from a second store, partial-refund reduction to USD 100.00, and full-refund reversal to zero. These are synthetic disposable-database tests, not live production verification; the production dashboard remains undeployed.


## 19 November — checkout provider-event retry gap closed in candidate source

- A cross-path review found that the signed MailerSend receiver returned HTTP 200 for an unmatched checkout event when the pixel-only reconciliation RPC returned `NOT_PIXEL_RECONCILABLE`. That acknowledgement could prevent MailerSend from retrying after the checkout attempt's provider message ID was persisted.
- The V2 receiver now returns retryable HTTP 503 only when the verified inbox row remains `UNMATCHED`, the signed payload contains a provider message ID, and pixel reconciliation says the event is not a pixel event. Checkout events already correlated by the inbox still receive normal acknowledgement; unmatched pixel events retain their existing retry path; events without a message ID do not enter this retry branch.
- Added a regression assertion and documented the provider retry/correlation contract and remaining connected gates.
- Exact code head `4081803ce930b1a69d14dd206e245613142729f4` passed the full Node suite **418/418**, focused identity/cost/privacy suite **215/215**, Gitleaks, Deno checks (including the MailerSend V2 webhook function), and disposable PostgreSQL migrations/lifecycle tests. Shopify app configuration validation passed and deployment was skipped.
- Documentation-only head `607c254d37e9075696c3e0ba13b9616730a36c81` also passed the latest identity validation and Shopify configuration workflows. PR #6 remains open, draft and unmerged. No production webhook, MailerSend account, Supabase project, n8n workflow, customer send or billing state was changed.


## 19 November — final checkout send authorization boundary added

- The checkout delivery Edge Function previously consumed a one-use permit and proceeded toward MailerSend without the final database recheck already present in the separate cart/browse delivery path.
- Added candidate migration 059, `202611190005_shopify_checkout_provider_submission_gate_v2.sql`, with a service-role-only final gate that rebinds the attempt to its exact permit, reservation, intervention, opportunity, checkout, consent, connection, app, tenant, provider, sender and billing rows. It rechecks active install/app/tenant state, open checkout and matching token, allowed jurisdiction, subscribed consent, same-store order absence, recipient suppression, privacy redaction guard, verified sender and reserved provider cost.
- The gate takes the exact Shopify connection row lock before locking permit/attempt rows, matching the uninstall processor's connection-first order and avoiding a lock-order inversion. Null jurisdiction and unknown consent fail closed.
- The checkout Edge Function now invokes this gate after permit consumption and immediately before the provider request. A rejected gate records the attempt as FAILED and does not call MailerSend.
- Added Node regression coverage for gate contents, lock ordering and Edge call order, plus a disposable PostgreSQL contract for the function definition, service-role-only grant and invalid-input fail-closed behavior. The CI workflow now applies 59 candidate migrations and executes both SQL and Node contracts.
- This is candidate source only. It does not eliminate the unavoidable narrow race between a completed database authorization transaction and an external provider request, and it is not a live uninstall/send test. No production database, Edge Function, MailerSend account, n8n workflow, Shopify installation or customer send was changed.
- **Exact candidate head `b618b33229ba5de5b6102b9d2b9b83427556004a` passed:** full Node suite **426/426**, focused uninstall/provider-gate contracts **8/8**, focused identity/cost/privacy contracts **215/215**, Gitleaks, repository Deno checks, and all 60 candidate migrations on disposable PostgreSQL. The new checkout gate SQL contract passed (`shopify_checkout_provider_submission_gate_passed`), as did the exact-store uninstall contract (`shopify_exact_store_uninstall_processor_contract_passed`). Shopify configuration/static and disposable database validation passed; deployment was skipped.
- This is candidate-only CI evidence. The SQL test verifies function structure, privilege boundary and invalid-input fail-closed behavior; it is not a live uninstall/send race test. No production database, Edge Function, MailerSend account, n8n workflow, Shopify installation or customer send was changed.


## 19 November — checkout ambiguous provider-event reconciliation

- A deeper checkout-versus-pixel comparison found a material asymmetry: pixel attempts retain a MailerSend provider message reference on an ambiguous result and can later reconcile `AMBIGUOUS → SUBMITTED`; checkout attempts previously discarded the message ID and their result RPC accepted only `AUTHORIZED` as a writable state.
- Added candidate migration 060, `202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2.sql`. Checkout result recording now retains a valid provider message ID when the result is ambiguous, keeps the merchant cost reservation `RESERVED`, permits only safe `AMBIGUOUS → SUBMITTED` reconciliation, rejects `AMBIGUOUS → FAILED`, and prevents changing an already-bound provider message identity.
- Added a provider-event mapping trigger for signed `activity.sent` events and a bounded `reconcile_unmatched_shopify_checkout_provider_events_v2` RPC. A second bounded RPC, `mark_stale_shopify_checkout_send_attempts_ambiguous_v2`, moves crashed/stale `AUTHORIZED` checkout attempts to `AMBIGUOUS` after two minutes, updates their intervention and keeps reserved cost held. It matches previously unmatched events by exact provider account + provider message ID, updates the matching attempt, and applies hard-bounce, unsubscribe and complaint suppressions using the original permit fingerprint. Duplicate events remain idempotent through the existing provider-event unique key and suppression source key.
- The reconciler performs no provider call, resend or reservation release for ambiguous attempts. It is designed to be invoked periodically by the existing Delivery workflow after candidate cutover; that live workflow has not been edited or executed.
- Added Node and disposable PostgreSQL contracts; CI migration manifest now contains 60 files. Validation is pending for this newest candidate head. No production database, Edge Function, provider account, n8n workflow or customer message was changed.
