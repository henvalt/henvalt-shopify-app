# PR #7 Scope and Release-Gate Audit — 2026-11-25

## Purpose

Record a read-only structural review of the current HENVALT V1 draft pull request. This document does not approve a merge, staging cutover, deployment, or production change.

## Exact revision reviewed

- Repository: `henvalt/henvalt-shopify-app`
- Pull request: [#7](https://github.com/henvalt/henvalt-shopify-app/pull/7)
- Base: `main` at `9bcba4e882543bece5f1b32ebec1befa46350191`
- Head: `work/48h-system-readiness-2026-11-21` at `f0c069d8b730572c836310383a214688ebc5ff2b`
- State: open, draft, unmerged; GitHub reports mergeable (no merge conflict)
- PR metadata: 1,630 commits; 244 changed files; +45,703 / -287
- Compare API: ahead by 1,630, behind by 0; merge base equals the reported base SHA.

## Changed-file distribution

| Area | Files |
|---|---:|
| Tests | 124 |
| Supabase | 61 |
| Documentation | 25 |
| n8n candidate builders / fixtures | 19 |
| GitHub Actions | 9 |
| Cloudflare | 3 |
| Dashboard | 1 |
| Shopify app config | 1 |
| Scripts | 1 |
| **Total** | **244** |

The Supabase portion contains 36 candidate migrations and 15 Edge Function source/handler files. The n8n portion contains sanitized active-workflow fixtures and candidate graph builders/contracts; it is not evidence that active production workflows were changed.

## Exact-head CI result

All nine PR-triggered workflow runs associated with the exact head above completed successfully:

| Workflow | Run ID | Result |
|---|---:|---|
| Integrated staging readiness contract | 45533299177 | success |
| Offline Shopify privacy HMAC contract | 45533299277 | success |
| Production-shaped delivery-generation migration | 45533299243 | success |
| Delivery-generation PostgreSQL model safety | 45533299346 | success |
| Shopify app configuration checks and deployment | 45533299200 | static validation and billing lock safety success; deployment skipped |
| Email usage reservation safety | 45533299178 | success |
| Billing lock safety | 45533299193 | success |
| Delivery lifecycle parent-first lock order | 45533299163 | success |
| Safety and pixel consent tests | 45533299186 | success |

These are CI and disposable-fixture results. They do not prove a live integrated Supabase + n8n + Shopify staging lifecycle.

## Review interpretation

1. The 1,630-commit / 244-file review surface is too broad to treat a green CI result or GitHub's `mergeable=true` as release approval.
2. The compare result establishes that the branch is 1,630 commits ahead of its merge base and not behind. It does not, by itself, establish whether the history is accidental, generated, or intentionally accumulated. Do not rewrite, reset, rebase, or merge the branch until its history and ownership are deliberately reviewed.
3. The current PR description includes historical candidate revisions and older CI evidence. Exact-head CI evidence above is the authoritative current run set for this audit.
4. Thirty-six candidate migrations span provider-send interlock, Shopify ingress/replay, privacy processing, revenue reconciliation, billing, quota reservation, and delivery-generation lifecycle. They require an ordered full-schema migration review in an isolated Supabase project before any production application.
5. Candidate n8n graph builders/contracts and sanitized workflow snapshots do not prove the active three workflows have been safely patched or that both provider-send routes are network-denied in an isolated environment.
6. Shopify app deployment was skipped. No app release is implied by the successful static validation job.

## Release decision

**NO-GO for merge-to-production, staging sign-off, and deployment.**

Remaining gates:
- Review the 1,630-commit history and reduce the PR to a deliberate, reviewable release sequence without destructive history edits.
- Provision or identify an approved isolated Supabase staging target and validate all candidate migrations against its full schema, roles, grants, Vault and Edge Functions.
- Prove all three workflows in isolated n8n staging, including replay/retry paths and both normal/manual provider routes, with provider egress denied and zero MailerSend calls.
- Verify privacy/unsubscribe/tracking/inbound-reply routes continue to operate while provider sending is stopped.
- Complete n8n execution-data minimization/redaction and provider credential emergency-revocation evidence.
- Complete fresh Shopify OAuth, webhook, pixel-to-recovery, attribution and dashboard lifecycle tests in staging.
- Obtain explicit owner approval before any production cutover.

## Safety boundary observed during this audit

This audit was read-only apart from writing this documentation file to the candidate branch. No production SQL, migration, Edge Function, Cloudflare Worker, n8n workflow, Shopify release, email, billing charge, or paid resource was changed or executed.


## Second-pass implementation review

The following source-level checks were performed after the initial scope inventory:

- Read the provider-send interlock migration. It defaults closed, revokes direct table/function access from application roles, serializes the global gate with a row lock, guards delivery-request claim transitions, and wraps the MailerSend credential-release RPC. The manual test-only message path is explicitly denied.
- Read the final provider-egress fence. It validates service role, tenant/request identity, parent intervention state, request state/channel/provider, generation freshness, and the global send gate before a one-way compare-and-set marker.
- Read the parent-first lifecycle lock-order migration. It rewrites four existing lifecycle RPC definitions using guarded `pg_get_functiondef` / `regexp_replace` substitutions. This is a sensitive source-preserving patch strategy; exact production schema/function-body compatibility must be proven against a full isolated schema before application.
- Read the quota reservation migration and its concurrency acceptance script. The billing-account row is locked before quota counts and reservation insertion; unresolved holds remain counted, ambiguous outcomes consume rather than release holds, and reservation transitions are audited.
- Confirmed the quota settlement trigger is attached to `delivery_attempts` inserts. A trigger's real behavior still depends on the complete upstream attempt-writing path and transaction boundaries, which the disposable fixture cannot fully establish.
- Read all three delivery-generation race scripts. They explicitly test retry-vs-late-acceptance, late-acceptance-before-egress, and egress-before-late-acceptance orderings using two PostgreSQL sessions and barriers.
- Read the retry-generation migration's worker lease checks. It validates tenant, worker, lease age, request, generation and retry-job mapping; the retry ceiling is three total generations (two automatic retries).
- Read the integrated-readiness test. It checks the exact three-workflow contract, immutable retry envelope, retry routing through the existing delivery workflow, and the three race fixtures.
- Read the staging identity preflight and its tests. The script is deliberately metadata-only and makes no network calls. Its PASS result trusts supplied environment strings such as `NETWORK_EGRESS_DENIED=true`, `WORKFLOWS_INACTIVE=true`, and `SHOPIFY_DEV_STORE_CONFIRMED=true`; it does not inspect firewall rules, actual n8n activation state, or Shopify store type. Therefore it is an input-validation gate, not evidence that staging is isolated or safe.
- Rechecked the exact-head workflow jobs on this audit commit: all nine workflow runs completed successfully; Shopify static validation and billing-lock checks passed, while `deploy-shopify-version` was skipped.

### Additional release gates from source review

1. Replace metadata self-attestation with independently collected evidence for network egress denial, actual n8n workflow state/IDs, Supabase project identity and Shopify development-store identity.
2. Apply the complete migration sequence only to a disposable isolated database with the real schema, extensions, roles, grants, triggers and functions; inspect the resulting function definitions and privileges after migration.
3. Exercise the real n8n worker graphs against the isolated database and stub provider, including webhook callbacks, retry job reclamation, quota settlement and late provider acceptance.
4. Verify that the one-way egress marker and global provider gate are enforced on every credential-release and HTTP-send path, including any legacy/manual or alternate code path.
5. Treat dynamic function-body rewrites in the lock-order migration as a compatibility risk requiring exact pre/post function-definition diff review.

No confirmed production defect was established by this read-only source inspection. The identified issue is evidentiary: the current preflight cannot independently prove the isolation claims it accepts. The NO-GO decision remains unchanged.


## Third-pass verification addendum — 2026-11-25 08:15 PKT

This addendum supersedes the older revision-specific status above where the values differ. Historical run IDs and prior-head counts are retained as history, not current status.

### Current PR and exact candidate revision

- Current reviewed head before this documentation update: `ec9ab6c9ad7740514e8d9899eb3915cb41642997`.
- PR #7 remains **open, draft, unmerged**; GitHub reports `mergeable=true`, which is only a merge-conflict signal.
- Current PR metadata: **1,632 commits**, **245 changed files**, **+45,805 / -287**.
- Compare `main...work/48h-system-readiness-2026-11-21`: **1,632 ahead / 0 behind**; merge base remains `9bcba4e882543bece5f1b32ebec1befa46350191`.
- The 245-file inventory includes 36 candidate Supabase migrations, 124 test files, 26 documentation files, 19 n8n candidate/fixture files, nine GitHub Actions workflows, three Cloudflare files, one dashboard file, one Shopify app configuration file and one script.
- GitHub reports no submitted PR reviews and no inline review threads. That is not equivalent to approval.

### Exact-head CI completion

All **nine of nine** PR-triggered workflow runs for `ec9ab6c9ad7740514e8d9899eb3915cb41642997` completed successfully:

| Workflow | Run ID | Result |
|---|---:|---|
| HENVALT integrated staging readiness contract | 45537862252 | success |
| Offline Shopify privacy HMAC contract tests | 45537862251 | success |
| HENVALT delivery lifecycle parent-first lock order | 45537862259 | success |
| HENVALT billing lock safety | 45537862264 | success |
| HENVALT production-shaped delivery generation migration | 45537862193 | success |
| Shopify app configuration checks and deployment | 45537862221 | static validation and billing-lock job success; deployment skipped |
| HENVALT delivery generation PostgreSQL model safety | 45537862412 | success |
| HENVALT email usage reservation safety | 45537862138 | success |
| HENVALT safety and pixel consent tests | 45537862233 | success; 88 steps, zero failed steps |

These results validate candidate code and disposable test fixtures only. They do not prove the full integrated live Supabase+n8n+Shopify environment.

### Additional migration review

A further source pass read the Shopify replay, privacy, billing, quota and delivery-generation migrations, including the dynamic lock-order rewrite and MailerSend webhook generation-routing patches.

- The lock-order migration has explicit existence, already-patched and anchor-mismatch guards around its four `pg_get_functiondef` rewrites. It remains sensitive to the exact deployed function bodies and must be verified with post-migration function-definition diffs in isolated staging.
- The MailerSend webhook patch adds exact delivery-tag matching for sent/delivered events and invokes late-acceptance settlement before ordinary result recording. Its dynamic replacement anchors are guarded; this source inspection is not a substitute for executing it against the full live function definition.
- The retry-generation worker wrappers preserve parent → request → background-job lock ordering and revalidate tenant, worker, lease age, generation and job mapping at authorization and final egress. The dedicated PostgreSQL model and race workflows passed on the reviewed head.
- No new confirmed production defect was established by this pass. The remaining blockers are compatibility and integration evidence, not an assertion that the live production system has been proven safe by CI.

### Current release decision

**NO-GO remains. Do not merge, deploy, apply migrations, modify active n8n workflows, release Shopify app versions, send provider traffic or create billable staging resources on the basis of these CI results.**

The two dominant unresolved gates remain:

1. The 1,632-commit / 245-file PR is too broad for a routine release review. Its history and ownership need deliberate review; do not reset, rebase, rewrite or merge it as a shortcut.
2. Staging isolation is not independently evidenced. The current preflight trusts operator-supplied metadata strings and does not inspect actual Supabase project identity, n8n workflow activation, Shopify development-store identity or network egress controls.

No production SQL, migration, Edge Function, Cloudflare Worker, n8n workflow, Shopify release, email, billing charge or paid resource was changed or executed during this third-pass review.


## Fourth-pass candidate artifact and ingress-result audit — 2026-11-25

### Generated workflow artifacts inspected

Inspected the actual JSON exports from successful HENVALT safety workflow run **45539824000**, produced on code head `344b572ded1fff499b342fc69ed0ba1ce5892099`:

| Candidate | Artifact ID | SHA-256 digest | Nodes |
|---|---:|---|---:|
| `HENVALT_INGEST_CANDIDATE_NO_SEND` | 14988831874 | `aa2be6df8c101386d66c9760511c9e456365607731a689666413499d7ee08948` | 71 |
| `HENVALT_RECOVERY_CANDIDATE_NO_SEND` | 14987868529 | `dd2b33c3d8a914536bcb3fa664a6e052f74da719264762cca2e46ef445cea7a9` | 74 |
| `HENVALT_DELIVERY_CANDIDATE_NO_SEND` | 14987973271 | `038ada2b17c9969d2f412be858dad3db46ce8108fdcfb42fe1bb83462332f13e` | 54 |

Direct inspection of all three JSON artifacts confirmed:
- Every candidate is inactive and `availableInMCP=false`.
- No node has a bound credential reference or live webhook ID.
- No production Supabase hostname remains in any export.
- Supabase endpoints use `supabase-staging.invalid`; the optional reply-AI endpoint uses `reply-ai-staging.invalid`. These are deliberate non-routable placeholders, not functioning staging services.
- Recovery's Execute Workflow nodes target the exact generated INGEST candidate ID `00000000-0000-4000-8000-999999999999` and DELIVERY candidate ID `00000000-0000-4000-8000-999999999996`.
- DELIVERY's outbound provider node is replaced by the deterministic `No-Send Provider Stub`, which returns HTTP 503 with `NO_SEND_CANDIDATE`. Its MailerSend webhook verification/inbound handlers remain present; no outbound MailerSend API host or provider-send node was found.
- These exports are offline artifacts, not imported or executed workflows. Their staging URLs cannot be used until replaced with independently verified isolated endpoints and isolated credentials.

### Additional regression tests added

- Commit `344b572ded1fff499b342fc69ed0ba1ce5892099` adds an INGEST builder test asserting that internal replay results terminate as subworkflow outputs and do not invoke the public webhook responder.
- Commit `b2d072a92940113658dc868f83304ba51bdf7873` adds a full-export test asserting every Supabase endpoint in the generated INGEST candidate uses the non-routable staging placeholder and that the candidate remains inactive, unavailable in MCP, credential-free and webhook-ID-free.
- Exact-head CI on `b2d072a92940113658dc868f83304ba51bdf7873`: all nine PR-triggered workflows completed successfully. Run IDs: 45540063769, 45540063847, 45540063839, 45540063805, 45540063861, 45540063870, 45540063865, 45540063747 and 45540063748. Shopify deployment was skipped.

### Interpretation and remaining boundary

The generated JSON artifacts now provide stronger evidence that the offline candidates are isolated from production endpoints and that the three workflow references line up. This does **not** establish that the imports are accepted by the target n8n runtime, that credentials are correctly rebound to a staging tenant, or that a synthetic Shopify event completes through the actual database and worker graph. No staging instance was imported or executed.

The PR remains draft and unmerged. The independent staging-identity/network-egress proof, full-schema migration compatibility, workflow runtime acceptance, execution-data retention/redaction and owner approval gates remain open. Production remains untouched.


## Fifth-pass write-map and provider-stub audit — 2026-11-25

- Cross-checked all 19 entries in `n8n/shopify-ingest-replay-write-map.json` against SQL definitions. Eighteen fenced wrappers are defined in migrations 009/010; the remaining candidate-only `process_shopify_order_edit_adjustment_fenced` is defined in migration 013. The latter calls `assert_shopify_replay_lease_for_write(job_id, worker_id, lease_id)` before invoking the legacy adjustment function in the same transaction and grants execution to `service_role` only. No mapped fenced function was missing.
- Inspected the generated DELIVERY candidate's actual graph, not just the builder source. The path is `Build Reply-To Address → No-Send Provider Stub → Classify Result → Should Record Provider Result?`; the no-send result has `should_record_result=false` and routes to `Build Delivery Response`, not `Record Delivery Result`. Thus the stub's synthetic 503 is not persisted as a provider attempt and cannot advance the recovery scheduler as if a real provider response occurred.
- Confirmed all generated webhook paths use the candidate-only `henvalt/candidate-no-send/...` prefix. The optional reply-AI HTTP call points only to `reply-ai-staging.invalid`; it is non-routable until a real isolated endpoint is independently approved.
- Exact-head CI on documentation head `270b6378f51e75b9f4be28b3a9ab786fa132ccc2`: all nine PR-triggered workflows completed successfully. Run IDs: 45540290776, 45540290771, 45540290999, 45540290828, 45540290744, 45540291031, 45540290740, 45540290739 and 45540290752. Shopify deployment was skipped.

These checks strengthen offline graph and SQL-map consistency evidence only. They do not prove runtime n8n import/execution, real isolated database credentials, network-denied egress, or the complete synthetic event-to-ledger lifecycle. The PR remains NO-GO for merge/deployment; production remains untouched.


## Sixth-pass exact-head and live-environment inventory — 2026-11-25

### Exact latest candidate CI

Rechecked PR #7 at exact head `7411964dce727270daf2cafa1b572f8dff568517`:

- All nine PR-triggered workflows completed successfully.
- Safety / Pixel-consent run `45540559992` completed all 88 steps with zero failed steps.
- Shopify configuration run `45540560150`: static validation and billing-lock safety succeeded; `deploy-shopify-version` was explicitly **skipped**.
- Other exact-head runs: integrated staging contract `45540560155`, offline privacy HMAC `45540560048`, delivery lifecycle lock order `45540560100`, production-shaped delivery migration `45540560011`, delivery-generation model `45540560078`, billing lock safety `45540560190`, and email usage reservation `45540560018`; all succeeded.

This is candidate CI evidence only. No Shopify deployment occurred.

### Fresh Supabase and n8n isolation inventory

Read-only inventory on 25 November established:

- Supabase organization plan: Free.
- Connected production project `ocyplckdojdubyrsxcxa`: `ACTIVE_HEALTHY`.
- Production project development-branch inventory: **zero branches**.
- Three other projects in the organization (`wrsediuhepdyajnihjoz`, `rurszafcjcmuudnoovfx`, `oajuebiofteafuootmxy`) are `INACTIVE`; none was restored.
- The Supabase branch quote for this organization is **USD 0.01344 per hour**. No branch or project was created. Restoring an inactive project or creating a branch was not attempted.
- n8n project search returns one personal project; team projects are not enabled. There is no separate n8n staging project available through the connected account.
- The n8n instance still exposes exactly three HENVALT workflows, all active:
  - INGEST `VTpfGKNtu1CSQ4Rv`, active version `6368d539-708f-494a-8be8-b9601d0e8607`, 51 nodes.
  - RECOVERY `3GEDoeCA4paXTaDF`, active version `3fd9fca9-a83f-4c2a-8618-24496a695eb8`, 46 nodes.
  - DELIVERY `CvVyybGJZSnklxiZ`, active version `621ae6ce-a006-4fed-a70e-acf774c360fb`, 62 nodes.

**Conclusion:** there is no independently isolated Supabase + n8n staging environment in the connected inventory. The production n8n project must not be used as a staging substitute. No branch, project, workflow, or deployment was created or changed.

### Fresh active-vs-candidate recovery configuration drift

Retrieved the exact active n8n RECOVERY version and compared its token-refresh query with the current generated candidates:

- Active production workflow version `3fd9fca9-a83f-4c2a-8618-24496a695eb8` selects offline tokens expiring within **5 minutes**.
- The current candidate builders select within **10 minutes**, matching candidate migration `202611210004_align_shopify_token_refresh_window.sql`.
- The candidate's intended 10-minute behavior therefore differs from the current active production scheduler. This is a deliberate candidate configuration change, not evidence that production has already adopted it. Isolated acceptance must verify the scheduler query and database claim threshold together before any cutover.
- The live RECOVERY claim query still filters only `execute_intervention`; its guard requires an `intervention_id`. It does not yet implement the candidate `process_shopify_webhook` replay-job route. The live workflow was not edited.

This fresh read supersedes older audit wording that described the current live scheduler as already using a 10-minute window.

### Current-head generated artifact provenance

Downloaded and inspected the actual artifacts attached to the exact-head safety run `45540559992`. They are offline exports, not imported workflows:

| Artifact | Artifact ID | Nodes | SHA-256 |
|---|---:|---:|---|
| INGEST candidate no-send | 14988079101 | 71 | `61ab4f84a0144f7b38cce66b32ac7d30a7270252655cf55dd6d27e3d0351cc41` |
| RECOVERY candidate no-send | 14988723098 | 74 | `29282b48f22b30dadc02eb780735ee85dcbe7469321819c20e702786a3b7cc7f` |
| RECOVERY candidate billing staging-only | 14988857713 | 76 | `e6fda1bdb32d0daabaf4f4d9d7bf285c8c7891a2cc2eda3f866cf9f3026db600` |
| DELIVERY candidate no-send | 14988508484 | 54 | `55adae40e925ca111281058d6e1d61296d6afb9ee14611bc5f7131a4bf6059dc` |

Direct JSON inspection confirmed for all four exports:

- `active=false`, `availableInMCP=false`, and no bound credential references.
- No production Supabase hostname and no MailerSend API hostname.
- Supabase destinations use the non-routable `.invalid` staging hostname.
- Delivery uses the deterministic no-send provider stub; inbound MailerSend signature/event routes remain separate from outbound sending.
- The billing-specific recovery artifact adds a measured-revenue billing-shop query and a worker call to the non-routable staging endpoint. Its SQL requires active tenants, active test-mode billing accounts, confirmed billable recovery ledger entries and eligible reconciliation state. The worker credential is intentionally absent and documented as a dedicated staging-only binding requirement.
- These properties establish offline artifact hygiene, not runtime import acceptance, working credentials, network-egress denial or successful end-to-end execution.

### PR review and scope status

- PR #7 remains open, draft, unmerged; GitHub reports mergeable, which is not approval.
- Current compare from main: 1,637 commits ahead, 0 behind; 245 changed files; +45,943 / -287.
- GitHub returned no submitted review records and no inline review threads. The issue timeline contains author/bot comments, not an independent code approval.
- The PR remains too broad for routine release review. Do not rewrite its history, merge it, or treat green CI as reviewer sign-off.

### Release decision

**NO-GO remains.** The missing isolated Supabase/n8n environment is a hard blocker; the quoted branch cost is nonzero and no paid resource was created. Full-schema compatibility, real workflow import/execution, independently enforced provider-egress denial, retention/redaction evidence, fresh Shopify event-to-ledger acceptance, legacy billing route disposition, and explicit owner approval remain open. Production database, Edge Functions, Cloudflare Workers, active n8n workflows, Shopify release, provider credentials, emails and billing charges remain untouched.


## Seventh-pass candidate billing cancellation/egress audit — 2026-11-25

### New candidate-only release blocker: no final billing authorization boundary

Read the candidate Shopify usage-billing handler, its test suite, and migrations 014–016. The current candidate sequence is:

1. `control_plane_claim_billing_usage` locks and checks the active billing account, then returns a claim envelope.
2. The Edge Function separately calls `get_shopify_access_token_for_control_plane`.
3. It then directly calls Shopify `appUsageRecordCreate`.
4. It records the provider result locally.

Migration `202611220015_billing_claim_subscription_lock.sql` explicitly says the billing-account row lock serializes the *claim decision* against cancellation, but does not make the later remote Shopify mutation atomic with cancellation. The token RPC only checks that the Shopify connection is active, not that the billing account is still active or the claimed charge remains authorized. There is no second billing-specific authorization/egress RPC between token retrieval and the Shopify mutation.

The existing `tests/shopify-usage-billing-worker.test.mjs` verifies claim-before-token ordering, test-mode refusal, idempotency, ambiguous provider outcomes and reconciliation. It does not simulate subscription cancellation after claim but before Shopify egress. The controlled-release runbook's cancellation matrix requires cancellation to be tested between claim, authorization and final egress, so the current handler/test contract does not yet meet that acceptance requirement.

**Disposition:** treat this as an unresolved candidate safety gap, not a confirmed production defect. Before even enabling the test-mode billing candidate in isolated staging, define the billing point-of-no-return and add a final server-side authorization step immediately before provider egress. It must revalidate tenant/shop binding, active subscription, test-mode state, charge identity/state, attempt and idempotency key; persist an auditable one-time authorization/lease; and define how cancellation interacts with already-authorized in-flight requests. Add race tests for cancellation before final authorization, cancellation after authorization, duplicate authorization and stale/replayed authorization. The acceptance contract must distinguish a denied pre-egress cancellation from an already-authorized in-flight request rather than claiming a distributed transaction across Postgres and Shopify.

### Current production boundary rechecked

A fresh read-only production inventory found:

- `billing_accounts`: one `PENDING`, `test_mode=true` account; zero ACTIVE billing accounts.
- Production Edge Function inventory does **not** contain `henvalt-shopify-usage-billing` or `henvalt-billing-reconciliation`.
- Production still has the older legacy control-plane claim/result RPC definitions. The candidate claim response's required `testMode=true` assertion therefore fails closed against that old schema if the candidate handler were accidentally pointed at production.
- No billing handler, migration, Edge Function, Shopify charge, or production state was changed during this inspection.

This confirms the cancellation/egress issue is confined to the un-deployed candidate design at present. It is nevertheless a release blocker because the candidate must be correct before any isolated test-mode charge is attempted.


## Eighth-pass billing egress authorization implementation — 2026-11-25

The candidate-only gap above now has an implementation and executable acceptance contract on this branch:

- Added `supabase/migrations/202611250001_billing_egress_final_authorization.sql`.
- Added service-role-only RPC `control_plane_authorize_billing_usage_egress`. It follows the claim lock order (shop connection → tenant → billing account → usage charge) and rechecks active shop/tenant/subscription, test mode, exact subscription line item, charge ID, immutable idempotency key, amount, currency and attempt count.
- The worker calls this RPC after obtaining the Shopify access token and immediately before the Shopify GraphQL mutation. Authorization errors fail closed; a denied authorization returns without a provider request or result mutation.
- The RPC persists `egress_authorized_at` and `egress_authorized_attempt` on the charge and writes one `BILLING_USAGE_EGRESS_AUTHORIZED` audit row per attempt. Repeating the same authorization for the same attempt is idempotent.
- Added handler tests for cancellation after claim, authorization-RPC outage, request ordering and exact charge-envelope binding.
- Added PostgreSQL acceptance for active test subscription, cancellation before final authorization, stale attempt rejection, changed line-item rejection, and idempotent audit-marker persistence. The billing CI workflow now applies the migration and runs this acceptance file.

### Explicit point-of-no-return limitation

This is not a distributed transaction with Shopify. The durable authorization marker defines the point-of-no-return: cancellation committed **before** the final authorization is denied; cancellation committed **after** the authorization marker does not revoke an already-authorized in-flight request. The external HTTP request can still fail or be delayed after authorization, so the existing Shopify idempotency key and PENDING/reconciliation behavior remain mandatory. The marker is auditable evidence of authorization, not proof that Shopify accepted the charge.

The candidate remains restricted to test-mode subscriptions. No migration was applied to production, no Edge Function was deployed, and no Shopify usage record was created. Exact-head CI and PostgreSQL acceptance are pending for this new commit; the PR remains draft/unmerged and the overall release decision remains **NO-GO** until those checks and isolated staging are complete.


### Verification result — candidate code commit `2459b396d3afe55438173372b32269e5d7caa546`

- Billing lock safety workflow `45543942550`: **success**. All 18 steps completed, including Node tests, bootstrap, migrations 011/014/015/016, the new final-egress migration, the new cancellation/stale-worker PostgreSQL acceptance, and concurrent refund-credit allocation.
- Safety and Pixel-consent workflow `45543942607`: **success**.
- Integrated staging readiness `45543942547`: **success**.
- Production-shaped delivery migration `45543942542`: **success**.
- Email usage reservation safety `45543942484`: **success**.
- Delivery lifecycle parent-first lock order `45543942588`: **success**.
- Delivery generation PostgreSQL model `45543942631`: **success**.
- Offline Shopify privacy HMAC `45543942529`: **success**.
- Shopify app configuration `45543942530`: static validation and billing-lock job **success**; deployment job **skipped**.

All 9/9 PR-triggered workflows completed successfully on the exact code commit above. This proves the candidate's automated contracts only; it does not prove an isolated Supabase/n8n runtime or Shopify provider acceptance. The overall release decision remains **NO-GO**.
