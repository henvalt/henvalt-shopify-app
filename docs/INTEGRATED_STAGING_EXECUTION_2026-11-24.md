# Integrated staging execution plan — 24 November 2026

**Status: PREPARATION / NOT STAGING-EXECUTED / NO-GO.**  
**Candidate base:** `56358cfd922b343240231614af44a40aaea527c8`  
**Work branch:** `work/48h-system-readiness-2026-11-21`

This plan closes the gap between individually passing PostgreSQL/Node/Deno checks and a real integrated environment. It does not claim that disposable PostgreSQL is equivalent to Supabase staging.

**Latest repository verification (25 November 2026):** candidate head `ce2dbd06531538bb3aa52e5db834f22f5cc5046f`. The integrated staging readiness contract, delivery-generation production-shaped migration suite, delivery-generation model/race suite, lifecycle lock-order suite, quota reservation concurrency suite, billing-lock safety suite, privacy/pixel safety suite, offline Shopify privacy HMAC contract, and Shopify static configuration checks all completed successfully on this head. These are CI/disposable-fixture results only; they do not change the NO-GO staging decision.

**Exact-head revalidation (25 November 2026):** after the documentation correction, GitHub Actions also completed successfully on exact PR head `46e4eb3e63e51c9b7de5b594ad6e5c9dc7a24d87`. The nine PR-triggered workflows were: lifecycle lock order (run `45532305676`), safety/pixel consent (run `45532305638`), production-shaped delivery-generation migration (run `45532305586`), email usage reservation (run `45532305606`), delivery-generation model (run `45532305632`), integrated staging readiness contract (run `45532305596`), Shopify app configuration (run `45532305584`), billing lock safety (run `45532305642`), and offline privacy HMAC (run `45532305630`). Every executed job concluded `success`; the Shopify deployment job was `skipped`, not deployed. This exact-head CI evidence still does not constitute integrated staging or authorize release.

## Hard safety boundary

- Never point a candidate workflow, Edge Function, Shopify app, or test harness at production.
- Do not create a paid Supabase project or other billable resource as part of this preparation.
- No production SQL, migration, Edge Function/Worker deployment, n8n workflow mutation, Shopify release, provider credential claim, email, or charge.
- Candidate delivery remains no-send. The provider boundary must be a network-denied stub, not merely a fake HTTP response in a live workflow.
- A missing staging resource or missing proof is a failed gate, not an assumed pass.

## Twenty-batch execution ledger

| Batch | Engineering work | Required evidence | State |
|---:|---|---|---|
| 01 | Pin candidate commit and PR lineage | exact SHA and branch recorded | DONE |
| 02 | Reconfirm active workflow identity | sanitized 2026-11-24 recovery snapshot | DONE |
| 03 | Preserve three-workflow topology | no fourth workflow; candidate IDs isolated | STATIC |
| 04 | Verify retry enqueue tenant binding | tenant + intervention + source job | STATIC |
| 05 | Verify source worker lease fencing | claimed status, worker ID, unexpired lease | STATIC |
| 06 | Verify expected request/attempt binding | stale request and attempt rejected | STATIC |
| 07 | Verify generation monotonicity | only current generation can resume | STATIC |
| 08 | Verify retry eligibility evidence | exact pre-provider marker + RELEASED reservation | STATIC |
| 09 | Verify ambiguous provider outcomes | no retry after uncertain egress/acceptance | STATIC |
| 10 | Verify bounded retries | generations 1–3; terminal dead-letter | STATIC |
| 11 | Verify immutable content envelope | same message, recipient and tracking token | STATIC |
| 12 | Verify recovery routing | retry job uses existing recovery worker | STATIC |
| 13 | Verify delivery lease propagation | job, worker and generation reach final gate | STATIC |
| 14 | Verify quota reservation behavior | released reservation is not double-consumed | CI |
| 15 | Verify lifecycle lock ordering | intervention → request → reservation/job | CI |
| 16 | Verify retry-wins race | late acceptance cannot overwrite newer generation | CI |
| 17 | Verify late-acceptance-wins race | no retry after provider acceptance wins | CI |
| 18 | Verify egress/late-acceptance race | final provider boundary is fenced | CI |
| 19 | Build isolated staging inventory and runbook | distinct Supabase, n8n, Shopify and provider identities | BLOCKED |
| 20 | Execute full integrated lifecycle | persisted state + zero provider egress + evidence bundle | BLOCKED |

**Interpretation:** DONE/STATIC/CI are repository-level preparation evidence. They are not staging acceptance. Batches 19–20 require a genuinely isolated environment and cannot be marked complete by source assertions.

## Integrated execution sequence

1. Establish a distinct Supabase staging project/branch and prove its project reference differs from production `ocyplckdojdubyrsxcxa`. If no free isolated environment is available, stop here; do not create a paid resource.
2. Record the exact candidate commit and ordered migration checksums. Apply migrations only to that isolated database, using a disposable snapshot of the required schema and synthetic tenant/customer/message records.
3. Deploy candidate Edge Functions only to the isolated project. Replace every external endpoint with an allowlisted staging endpoint. Do not copy production secrets or provider tokens.
4. Import the sanitized INGEST, RECOVERY and DELIVERY candidates into a separate n8n instance/workspace. Verify distinct workflow IDs, inactive state, no credential objects, no production URLs and no live provider nodes.
5. Enforce outbound network denial at the staging runtime/container boundary. A fake response node alone is insufficient evidence that an alternate route cannot reach MailerSend.
6. Run one synthetic checkout through durable ingest, recovery eligibility, intervention creation, delivery generation 1, pre-provider failure, quota release, retry job enqueue, generation 2 claim and completion.
7. Inject a worker crash after claim; prove lease expiry and reclaim do not permit the stale worker to enqueue or deliver.
8. Inject crash after generation creation but before source-job completion; prove idempotent retry command mapping returns the same retry job and does not create generation 3 accidentally.
9. Inject delayed provider acceptance and run both race orderings: retry wins first; late acceptance wins first. Also test acceptance after egress has begun.
10. Cancel billing / revoke delivery entitlement between queue and claim, between claim and authorization, and between authorization and final egress. Every later boundary must deny safely; no new credential may be released.
11. Assert tenant A cannot read, claim, load, retry, settle or complete tenant B's job, request, attempt, reservation or provider event.
12. Reconcile all durable records: source job, retry command, retry mapping, retry job, request generation, attempt, reservation event, provider event and intervention terminal state.
13. Export an evidence bundle containing exact IDs, state transitions, SQLSTATEs, timestamps, workflow versions, Edge Function versions, outbound network-denial logs and test results. Use synthetic identifiers only.

## Required stop conditions

- Any staging endpoint resolves to production.
- Any workflow is active before the no-send tests pass.
- Any provider credential is available to the runtime.
- Any test causes a real external provider request.
- A stale worker can mutate a newer generation.
- A delayed acceptance can create a second deliverable request.
- A cancelled tenant can cross the final egress boundary.
- Tenant mismatch, missing lease, malformed generation or missing billing state fails open.
- Any expected database transition is missing or duplicated.

## Acceptance decision

The new static regression test `tests/integrated-staging-readiness.test.mjs` checks that the repository's staging contract remains tied to the exact three-workflow topology and existing retry/race/reservation acceptance artifacts. It is deliberately not a claim that staging has run.

The final gate is **NO-GO** until batches 19 and 20 have real environment evidence. The current connected production project has no verified isolated development branch, so this branch must not attempt to substitute production for staging.
## Preflight tool

Before any staging mutation, run:

```bash
node scripts/staging-identity-preflight.mjs
```

The tool requires explicit metadata for the staging Supabase ref, HTTPS n8n URL and three distinct workflow IDs, an explicit HTTPS `HENVALT_STAGE_DASHBOARD_URL` matching the isolated staging application origin (map it to the OAuth function's `HENVALT_DASHBOARD_URL` setting), Shopify development-store confirmation, the exact staging Supabase OAuth callback URL, a staging HTTPS `/shopify/webhooks` ingress URL, provider stub mode, network-denial proof, no-send flag, `HENVALT_SHOPIFY_BILLING_EGRESS_ENABLED` unset, and inactive-workflow confirmation. It rejects the live production Supabase project ref, all three inspected live production n8n workflow IDs, the known production n8n hostname, and the live production Cloudflare webhook Worker hostname. It verifies that the OAuth callback hostname is exactly `<staging-project-ref>.supabase.co` and that its callback path is exact. Separately verify that this exact callback URL is present in the Shopify app\u0027s `redirect_urls` allowlist (or use a dedicated staging app configuration); a correct Supabase hostname alone does not make Shopify accept the callback. Never replace the production callback with the staging callback. It makes no network requests and does not access credentials. For no-send acceptance, the billing worker must refuse before any database/token/provider request unless the flag is exactly `true`; keep it unset, and independently deny public egress to MailerSend and Shopify Admin GraphQL at the runtime boundary. Confirm `billing_measurements` may be created for confirmed recoveries but no `billing_usage_charges` row or Shopify `appUsageRecordCreate` request is created. The billing scheduler remains a branch inside RECOVERY; do not add a fourth workflow. Passing preflight is identity/safety evidence only, not integrated acceptance.

Environment variables are intentionally not documented as values here; populate them from verified staging inventory only. Never paste production secrets.

The staging Cloudflare Worker must expose `POST /shopify/webhooks`, set `HENVALT_STAGE_N8N_HOST` to the exact staging n8n hostname, and set `N8N_INGEST_URL` to the exact HTTPS webhook URL on that same host ending in `/webhook/henvalt/ingest-candidate-no-send`. The Worker rejects any host that does not exactly match the explicit allowlist, in addition to rejecting known production n8n hosts. The Worker must verify Shopify HMAC over the raw bytes, forward only the allowlisted Shopify headers, and return HTTP 200 only for the durable acknowledgement envelope containing a webhook UUID and active replay-job UUID/status. Generic 2xx, 204, malformed acknowledgement, or missing replay job must remain retryable 503 responses. The Supabase ingress RPC independently verifies the signed raw body and atomically persists the webhook plus replay job.


## Live staging-boundary recheck — 2026-11-25

A fresh read-only inspection of the connected Supabase and n8n accounts was performed after the candidate CI work:

- Supabase currently exposes four HENVALT-related projects: one active healthy project and three inactive projects. The active project is the existing HENVALT production project. On 2026-11-26, the existing henvalt_v23 project restore request was accepted to investigate a zero-new-resource staging option; it is still COMING_UP, so its schema, secrets, functions and data have not yet been inspected and it is NOT approved as staging. No project or branch was created, and no migration or Edge Function was applied.
- n8n workflow search returned exactly the three existing HENVALT workflows: INGEST (51 nodes), RECOVERY (46 nodes), and DELIVERY (62 nodes). All three are active, and their active version IDs match their current published versions. A separate staging workflow search returned zero results.
- The live INGEST workflow includes direct calls to the production Supabase host and has live webhook IDs/credentials. The active workflows were inspected read-only only; none was executed, changed, unpublished, or republished.

**Result: staging still cannot safely proceed.** The existing inactive Supabase projects cannot be treated as staging based on their names or paused state; the current n8n account has no separate staging workflow set. Reusing the active project or active workflows would violate the isolation requirement. Restoring or creating infrastructure could incur charges, so no such action was taken.

The release gate therefore remains **NO-GO** pending a verified, cost-approved isolated Supabase project and a separate n8n staging workspace/project with outbound provider egress blocked.

## Live infrastructure audit — 2026-11-26

This section supersedes earlier assumptions about the available staging boundary. All observations below are read-only except the explicitly recorded restore request for the already-existing paused henvalt_v23 project.

### Supabase

- Organization plan: Free.
- Active production project: ocyplckdojdubyrsxcxa.
- Existing paused projects: henvalt_v23, henvalt-sales-factory, henvalt-core-vault.
- Existing development branches: zero.
- A new branch quote is USD 0.01344/hour, so it is excluded from the no-paid-resource plan.
- Three existing paused projects were restored one at a time for read-only inspection, then returned to pause because they were legacy schemas with RLS-disabled public tables: henvalt_v23 (10 public tables, all zero rows, 0 migrations, 0 Edge Functions), henvalt-sales-factory (2 public tables, all zero rows, 0 migrations, 0 Edge Functions), and henvalt-core-vault (11 public tables plus vault.secrets, all inspected row counts zero, 0 migrations, 0 Edge Functions). The first two are confirmed INACTIVE; the last pause request was accepted and last observed as PAUSING. None is approved as staging.
- The active production project currently has deployed OAuth, MailerSend delivery, control-plane and dashboard Edge Functions. Candidate Shopify usage billing is not among the deployed function names. Do not test the active project's delivery endpoints.

### Cloudflare and domain routing

- Connected Cloudflare account currently lists seven Workers and zero Cloudflare zones.
- The existing henvalt-clean-ingress-v1 Worker is production-bound. Its N8N_INGEST_URL points to https://n8n.henvalt.com/webhook/henvalt/ingest; its current source returns HTTP 200 whenever the upstream responds with any successful status and does not validate the durable webhook/replay-job acknowledgement. This differs from the hardened repository candidate at cloudflare/worker.js, which requires a durable UUID acknowledgement and returns retryable 503 for generic/empty/malformed 2xx.
- The production Worker must remain untouched. The dedicated staging Worker name is henvalt-shopify-ingress-staging-no-send, with the exact hostname henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev. It uses cloudflare/staging-worker.js, a separate wrangler.staging.toml, staging-only SHOPIFY_API_SECRET, HENVALT_STAGE_NO_SEND=true, provider_mode=stub, and the candidate durable-ack source. The wrapper rejects production n8n hosts, a wrong webhook path, missing no-send mode, and live provider mode before forwarding.
- Cloudflare account's workers.dev subdomain is enabled. The domain henvalt.com is registered with Hostinger and uses Hostinger nameservers, not a Cloudflare zone.
- Hostinger DNS currently points app.henvalt.com and n8n.henvalt.com to 43.161.214.33; the apex points to Vercel and www uses a Vercel DNS target. Hostinger account inventory shows one Premium plan and one Horizons website, but no VPS instances. Do not assume the server at 43.161.214.33 is controlled by this Hostinger account.

### Dashboard preview

- An existing Cloudflare Pages project henvalt-dashboard-preview is connected to this repository and has successfully deployed the current candidate branch. Its branch alias is https://work-48h-system-readiness-20.henvalt-dashboard-preview.pages.dev.
- The preview project currently has no environment variables. dashboard/index.html explicitly disables its live API outside henvalt-dashboard.pages.dev and contains production Supabase project constants. The preview URL is therefore a safe visual preview only, not a connected staging dashboard.
- The branch now adds dashboard/functions/config.js, which returns production config only on the exact production host and staging config only when HENVALT_STAGE_NO_SEND=true plus a non-production project ref, exact Supabase URL and publishable key are present. The dashboard UI blocks MailerSend setup and billing-resolution POSTs in no-send mode. The preview remains disabled until its preview environment receives HENVALT_STAGE_SUPABASE_PROJECT_REF, HENVALT_STAGE_SUPABASE_URL, HENVALT_STAGE_SUPABASE_PUBLISHABLE_KEY and HENVALT_STAGE_NO_SEND=true. None of these variables has been set yet; do not point the preview at production endpoints.

### Shopify app configuration

- The repository's default shopify.app.toml is explicitly production-bound: it uses the existing production client ID and the production Supabase OAuth callback and privacy webhook URL.
- Never run Shopify CLI deploy/release using the default config for staging. A dedicated staging app identity and a separately rendered staging config are required. The exact staging callback must be added to that staging app's Shopify redirect allowlist.
- A staging config renderer now generates a separate shopify.app.staging.toml from explicit staging-only client ID, dashboard URL, Supabase project ref and privacy endpoint values. It rejects the production app client ID, production project ref and known production app hosts; it is covered by CI tests and does not create or deploy a Shopify app.
- The manual signed-webhook GitHub workflow has been changed to require a staging-only Shopify secret, explicit staging ingress repository variable and HENVALT_STAGE_NO_SEND=true; its former hard-coded production endpoint has been removed. It cannot be run until a verified staging endpoint is configured.

### n8n access

- Last successful live inspection found exactly three active production workflows, with no separate staging workflow set.
- The n8n connector returned internal errors during this 2026-11-26 pass, so workflow inventory could not be refreshed. Do not infer a staging workspace exists; retry read-only inspection before any workflow creation or execution.

### Production Supabase advisor audit — 2026-11-26

Read-only Supabase advisors reported:

- 11 internal henvalt tables have RLS enabled and no policies. This is INFO, not a public exposure: client roles are denied by default. Do not add broad policies merely to silence the linter.
- henvalt.is_tenant_member(p_tenant_id) is SECURITY DEFINER and callable by authenticated. Its current definition only returns EXISTS for tenant_memberships where user_id = auth.uid(), with a fixed search_path of henvalt, pg_temp. This is an intentional membership-check contract; no change made.
- Supabase Auth leaked-password protection is disabled. This is a security-hardening recommendation, not changed in this pass.
- One unindexed foreign key remains: henvalt.shopify_privacy_requests.tenant_id. Candidate index can be added in a later migration after staging baseline validation.
- 62 indexes are reported unused. They were not dropped; the database is low-traffic and these indexes may support production query paths not yet exercised.

No production SQL, settings or indexes were changed.

### Current conclusion

The production boundary is now better understood, and all three existing paused projects have been inspected; none is a safe staging baseline. The organization currently has one active production project and room for a second free project, but a new project cost quote and organization selection are required before creation. There is still no verified isolated end-to-end staging environment. The restored legacy projects inspected so far are not ready, n8n staging access is unverified, and the dedicated staging Worker and Shopify app configs are prepared but not deployed or registered. NO-GO remains in force.


### Integrated staging execution — 2026-11-26

A dedicated second Supabase project was created in the existing Henvalt organization after the user approved the Free-plan-only option and the project cost quote returned $0/month. The project is isolated from production and is healthy. Its project reference and API keys are intentionally not recorded in this repository.

#### Production-shaped baseline

The staging baseline was reconstructed from read-only PostgreSQL catalogs of the active production project. Only schema metadata and routine definitions were transferred; no production rows, credentials, Vault secrets, customer data, or access tokens were copied.

The initial baseline matched production exactly across fingerprints for:
- 41 tables and 464 columns
- 14 enums
- 206 constraints (including 80 foreign keys)
- 173 indexes
- 123 functions
- 32 RLS policies
- 5 triggers
- RLS enabled on all 41 tables

The exact fingerprints for columns, constraints, indexes, functions, policies, triggers, and RLS settings matched before candidate migrations were applied. Six baseline migrations record the structure-only import.

#### Candidate migrations and test results

All 37 candidate migrations from this branch were applied to isolated staging. Two migration scripts needed a compatibility correction because the provider interlock migration wraps the public MailerSend credential-release RPC and moves the original claim implementation to `get_mailersend_token_for_delivery_legacy_v1`. The lifecycle lock-order and legacy one-off shutdown migrations now target that private implementation. The lock-order workflow now applies the provider-interlock prerequisite first, and its acceptance tests explicitly open and then close the test gate.

The resulting staging schema has 49 application tables, 199 functions, and RLS enabled on all 49 tables. The global provider-send interlock is confirmed closed. Supabase security advisors report 19 INFO-level internal tables with RLS enabled and no policies; these remain server-only and have no client grants. No critical advisor finding was reported in the staging security pass.

PostgreSQL acceptance checks passed for:
- Production-shaped delivery generation and retry authorization
- Immutable retry-job creation and envelope loading
- Late provider acceptance and incident handling
- Exact-tag MailerSend webhook routing
- Provider-send interlock default-deny, credential release and token-refresh behavior
- Parent-first lifecycle lock ordering and legacy one-off shutdown (full disposable schema workflow)

The billing final-egress authorization acceptance script also completed without SQL errors. It exercised exact charge-envelope matching, repeat authorization idempotency, subscription cancellation, stale-attempt rejection, and changed subscription-line-item rejection. Its test marker was persisted only in staging; no Shopify usage API request was made.

#### Safety boundary and remaining integration work

- No production SQL, migrations, settings, Edge Functions, Cloudflare Workers, or n8n workflows were changed.
- No email was sent and no Shopify billing mutation was made.
- The staging provider-send gate remains closed.
- No staging n8n runtime has yet been verified or connected.
- The dedicated staging Shopify app identity and its credentials/callbacks still need to be created.
- The staging Cloudflare ingress Worker has not been deployed or connected to a staging n8n endpoint.
- The dashboard preview remains backend-disabled until staging runtime configuration is safely supplied.
- PR #7 remains draft and unmerged; the full review surface is still too large for a safe merge.

The system remains **NO-GO for merchant launch** until a synthetic Shopify checkout traverses the isolated ingress, durable replay, recovery, generation-bound delivery authorization, blocked provider-egress boundary, order attribution, and billing measurement end to end. No production cutover is authorized by this staging work.


### Dashboard RPC privilege audit — 2026-11-26

A staging-only security review of the dashboard Edge Function and its two SECURITY DEFINER reporting RPCs found that both RPCs were executable by `anon` and `authenticated`. Because they accept a shop domain and do not independently verify the caller's tenant membership, direct PostgREST RPC invocation could bypass the Edge Function's membership resolution and disclose merchant reporting data.

Remediation applied to the isolated staging project and committed as candidate migration `202611260001_dashboard_reporting_rpc_service_role_only.sql`:
- Revoke all direct execution from PUBLIC, anon, and authenticated.
- Grant execution only to service_role, which is used by the dashboard Edge Function after it validates the user's access token and resolves exactly one tenant membership and active Shopify connection.
- Staging verification passed: anon=false, authenticated=false, service_role=true for both RPCs.
- Added a disposable PostgreSQL 17 CI workflow and SQL acceptance test to prevent regression.

No production grants or functions were changed. The staging dashboard Edge Function is present, but the other production Edge Functions (OAuth, ingress/control plane, delivery, billing, etc.) have not yet been deployed to staging. The dashboard preview remains unconfigured and backend-disabled. End-to-end Shopify testing remains blocked on a dedicated staging Shopify app identity and a usable isolated n8n runtime.


### Full RPC privilege parity correction — 2026-11-26

The deeper ACL comparison found that the initial structure-only staging reconstruction had not preserved PostgreSQL function ACLs/default privileges. This was not a production defect: the production inventory had 118 SECURITY DEFINER functions, zero executable by anon, one executable by authenticated (`is_tenant_member`), and all 118 executable by service_role. The first staging reconstruction had inherited PUBLIC EXECUTE on 109 SECURITY DEFINER functions because the schema import did not carry the original ACL/default-privilege configuration.

This staging mismatch is now corrected:
- `202611260001_dashboard_reporting_rpc_service_role_only.sql` closes direct client execution for the two dashboard reporting RPCs.
- `202611260002_harden_security_definer_rpc_grants.sql` revokes PUBLIC/anon/authenticated execution from all SECURITY DEFINER functions, grants service_role, preserves the authenticated `is_tenant_member(uuid)` RLS helper, and explicitly restricts candidate-only internal helpers. The migration is ordered after all function-creating migrations; CI fails if a later SECURITY DEFINER function is added without the same hardening.
- Staging now has 190 SECURITY DEFINER functions: anon execution **0**, authenticated execution **1** (`is_tenant_member` only), service_role execution **190**. This matches the production privilege pattern while accounting for candidate-only functions.
- Non-SECURITY DEFINER public helpers now match production's exposed helper list (only `render_email_plain_text` and the trigger helper `stamp_recovery_intervention_delivery_times` in addition to `is_tenant_member`).
- A dedicated PostgreSQL 17 CI workflow tests both the exact dashboard RPC grant boundary and the complete SECURITY DEFINER/default-privilege policy. Its first run exposed a shell-heredoc quoting defect in the test fixture; that fixture was corrected and the new workflow has been queued again.

The ACL parity issue was discovered in isolated staging and fixed there only. Production ACLs, SQL, Edge Functions and service settings remain unchanged.


### Dashboard preview runtime isolation — 2026-11-26

Cloudflare Pages project `henvalt-dashboard-preview` now has preview-only environment variables pointing to the dedicated staging Supabase project:
- `HENVALT_STAGE_NO_SEND=true`
- staging project reference and matching Supabase URL
- staging `sb_publishable_` key only

The latest preview deployment for commit `b5660c1969b51e06c495688e6cadd855a0d1d75c` completed successfully with Pages Functions enabled:
`https://61270f23.henvalt-dashboard-preview.pages.dev`

The preview runtime now exposes only the deployed staging merchant-dashboard API. Staging billing reconciliation, privacy export, Shopify OAuth and MailerSend setup endpoints are explicitly null/unavailable until their corresponding isolated Edge Functions and Shopify app identity exist. The no-send dashboard hides billing/privacy navigation and Shopify reauthorization, and guards those actions in code. This prevents the preview UI from calling production or nonexistent staging endpoints. The production dashboard hostname/configuration was not changed.

The Pages API confirms the environment configuration and successful deployment stages. A direct HTTP fetch of the preview `/config` endpoint was not available through the web inspection channel, so endpoint response content is not claimed as independently fetched.


### OAuth endpoint identity hardening — 2026-11-26

A source review found that the OAuth function validated ingress and pixel collector URLs as HTTPS, but did not bind either endpoint to the isolated staging host inventory. That left a misconfiguration path where a staging OAuth install could register Shopify webhooks against an unintended HTTPS destination or initialize the web pixel against a production collector.

The candidate now treats every Supabase project other than the explicitly identified production project as non-production and requires exact host bindings for both endpoints:
- `HENVALT_STAGE_INGRESS_HOST` must equal the dedicated staging ingress Worker hostname.
- `HENVALT_STAGE_PIXEL_COLLECTOR_HOST` must equal the dedicated staging pixel collector hostname.
- `SHOPIFY_WEBHOOK_INGRESS_BASE_URL` must use the exact ingress host.
- `SHOPIFY_PIXEL_COLLECTOR_URL` must use the exact collector host and `/v1/events` path.
- Staging preflight now requires the corresponding explicit host and URL metadata, rejects the known production pixel collector hostname, and checks the ingress host against the dedicated no-send Worker.
- The production Supabase project retains its existing non-strict endpoint configuration path; no production function was changed.

The staging OAuth deployment environment must map the two `HENVALT_STAGE_*_HOST` values alongside the corresponding `SHOPIFY_*_URL` values. Do not deploy OAuth until a dedicated staging pixel collector exists and its actual hostname has been verified. The current Cloudflare inventory has no dedicated staging pixel collector, so this gate is intentionally still blocked. The change is candidate-only and does not imply a successful OAuth runtime test.

The required staging pixel collector identity is pinned to `henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev`; the existing `henvalt-pixel-collector` Worker is production and must never be supplied as the staging host. Its dedicated Worker, staging Supabase publishable key, collector shared secret, and isolated rate-limit binding must be provisioned before OAuth deployment. The current Cloudflare inventory confirms that this staging Worker does not yet exist.


### Dedicated staging pixel collector candidate — 2026-11-26

A separate Cloudflare Worker entry point now wraps the existing pixel collector for isolated staging:
- Worker identity: `henvalt-pixel-collector-staging-no-send`.
- Config: `wrangler.pixel-staging.toml`; entry point: `cloudflare/staging-pixel-collector.js`.
- It requires `HENVALT_STAGE_NO_SEND=true`, the exact staging Supabase hostname `xidhtmrfvsgfmyltjuja.supabase.co`, an `sb_publishable_` key, a collector shared secret of at least 32 characters, and a rate-limit binding.
- Invalid or missing configuration blocks event POSTs before any Supabase request. Health reports whether the configuration is complete without exposing secrets.
- The worker requires two secrets to be configured at deployment time: `SUPABASE_PUBLISHABLE_KEY` and `COLLECTOR_SHARED_SECRET`. The rate-limit binding uses its own namespace and must remain separate from production.
- Unit tests cover exact project binding, production/arbitrary host rejection, required safety configuration, and fail-closed health behavior. CI now executes these tests and validates the dedicated Wrangler config.

This is candidate code only. The Worker has not been deployed, secrets have not been configured, and no pixel event has been sent. The staging Shopify OAuth function must remain undeployed until the dedicated ingress and pixel collector Workers and isolated n8n endpoint are all provisioned and verified.

### Dedicated Cloudflare staging Worker deployment — 2026-11-26

Two isolated Cloudflare Worker scripts have now been uploaded from the reviewed candidate branch:

- `henvalt-shopify-ingress-staging-no-send`, version 1 / deployment `e21dfc2d-43e7-41b6-9445-6266cb2d2491`.
- `henvalt-pixel-collector-staging-no-send`, version 1 / deployment `2e240f2e-88b2-422e-9ed5-232a557a6329`.

Both scripts were verified through the Cloudflare API after upload. Their `workers.dev` subdomains and preview URLs remain **disabled**, and both scripts have zero configured secrets.

The ingress script is bound only to no-send/stub flags and the deliberately invalid `staging-n8n.invalid` destination. The Shopify HMAC secret is absent, and the staging host/path guard rejects the placeholder. The pixel collector is bound only to the isolated staging Supabase URL and no-send flag; its publishable key, collector shared secret, and rate-limit binding are absent. Its configuration guard therefore remains closed.

These are deployed fail-closed artifacts, not operational endpoints. No Shopify webhook or pixel event was sent; no n8n, Supabase, Shopify, provider or production Worker configuration was changed. Do not enable either public subdomain or configure secrets until the isolated n8n endpoint, staging-only Shopify app credentials, and pixel rate-limit binding have been verified. Public health smoke tests remain pending because the subdomains are intentionally disabled.
