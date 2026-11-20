# No-send cutover acceptance and controlled staging plan

**Checkpoint:** 20 November 2026  
**Scope:** candidate branch / PR #6 only  
**Decision:** NO-SEND ACCEPTANCE PARTIAL; STAGING PLAN PREPARED; PRODUCTION HOLD

This document records the evidence required to move HENVALT from candidate CI into a controlled, non-production rehearsal. It is not deployment authorization.

## 1. Non-negotiable boundary

Until a separate written approval names the exact environment and action:

- Do not merge PR #6.
- Do not apply candidate migrations to production.
- Do not deploy or replace production Edge Functions or Cloudflare Workers.
- Do not edit, execute, activate, deactivate, import over, or publish the three live n8n workflows.
- Do not change Shopify app settings, webhook subscriptions, OAuth credentials, or release an app version.
- Do not change MailerSend event destinations, sender configuration, credentials, or readiness flags.
- Do not send customer email, create a billing transaction, or enable fee collection.
- Do not create paid infrastructure or a Supabase branch/project without an explicit cost review and approval.

The live workflow identities remain exactly `HENVALT_INGEST`, `HENVALT_RECOVERY`, and `HENVALT_DELIVERY`. No fourth production workflow is permitted.

## 2. Evidence baseline

The current PR #6 candidate includes:

- A composed offline Recovery → Delivery runtime with injected fetch transport.
- Strict work-type/UUID validation, complete-batch validation before handoff, opaque-only checkout/pixel dispatch, separate delivery credentials, conservative response classification, and lease-finish acknowledgement.
- Offline acceptance cases for 401/403/409/429/503, permanent 400/422, deferred 404/410, recorded provider rejection, accepted ambiguous 202, malformed JSON, transport exceptions, and secret/recipient redaction.
- Disposable PostgreSQL contracts for exact-store identity, consent and suppression, provider authorization gates, cost reservations, concurrent claims, uninstall stop behavior, privacy boundaries, and attribution/fee-ledger integrity.
- Candidate migration validation through migration 060, Gitleaks, Node regression tests, Deno checks, and Shopify static/configuration checks.

After the initial plan commit, the empty-queue regression was added in code commit `d19c18671dea00ac3165bf6c9b2ca77b766d39a1`. The latest no-send regression batch is code commit `26a8c362003431a31dc14f7bcb28bb9f28a0952d`. Exact-code CI for that SHA passed: identity V2 run [44721075413](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44721075413) reports Node **455/455**, focused provider/uninstall **13/13**, identity/cost/privacy **224/224**, Gitleaks, Deno checks, candidate migrations 001–060, and the two-session attribution race. Shopify configuration run [44721075269](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44721075269) passed static and disposable migration validation; the app deployment job was skipped. The 455-test run includes the empty-queue, mixed checkout/pixel opaque-routing, and invalid-later-item whole-batch rejection regressions. Earlier CI on `d19c186` remains historical evidence only; each later code SHA must be validated independently.

These results are candidate CI evidence only. They do not prove the production schema, deployed Edge Functions, live n8n graph, Shopify ownership, sender configuration, or provider behavior.

## 3. No-send acceptance matrix

A case passes only when the provider boundary is structurally intercepted or disabled and the test fails on any unexpected provider request. A test title containing “dry run” is not evidence by itself.

| ID | Scenario | Required assertion | Current evidence / disposition |
|---|---|---|---|
| NS-01 | Empty candidate set | No claim, no delivery handoff, zero provider calls | PASS on `d19c186`: regression observed in CI; 453/453 Node tests passed, with zero lease finish, Edge Function call, or provider request |
| NS-02 | Checkout candidate | Only checkout intervention is materialized/claimed; checkout endpoint receives only intervention ID | PASS in offline composed fixture on `26a8c36`: mixed batch routes checkout work only to contact-delivery endpoint with `{ intervention_id }` and checkout-only bearer credential |
| NS-03 | Pixel candidate | Pixel opportunity remains pixel work; no checkout intervention fabricated | PASS in offline composed fixture on `26a8c36`: same mixed batch routes pixel work only to pixel-delivery endpoint with `{ opportunity_id }` and pixel-only bearer credential |
| NS-04 | Concurrent workers | Exactly one active lease for the same work item | Disposable PostgreSQL concurrent claim contract passed |
| NS-05 | Deferred/reclaimed lease | Reclaim gets a fresh lease ID; stale lease cannot finish | Disposable lease lifecycle contracts; include in end-to-end staging run |
| NS-06 | Invalid work / malformed UUID / wrong-store ID / missing auth | Zero provider calls; fail closed | PARTIAL on `26a8c36`: malformed UUID in a later batch item rejects the entire batch before any Edge handoff or lease mutation; wrong-store ID and missing-auth end-to-end cases remain open |
| NS-07 | Inactive tenant/app/connection; missing or unverified sender; absent consent/contact/jurisdiction; suppression; recovered order; no cost entitlement | Zero provider calls | Candidate SQL and Edge-function authorization contracts; no live provider call is permitted |
| NS-08 | MailerSend readiness false or unsubscribe insertion unverified | Zero provider calls | Candidate delivery gate contract; verify in staging using synthetic provider config |
| NS-09 | Accepted handoff | Lease completes only after explicit allowlisted accepted response and confirmed finish acknowledgement | Offline composed runtime tests, including lease-finisher acknowledgement regression |
| NS-10 | Permanent ineligibility | Terminal only for documented allowlisted permanent reasons | Offline status matrix covers 400/422 and definite recorded provider rejection |
| NS-11 | Timeout / 429 / 5xx / malformed response | Defer or reconcile; never issue a fresh duplicate send | Offline composed tests; ambiguous attempt lifecycle covered in disposable DB tests |
| NS-12 | Signed provider test event | Raw-body signature verified; URL validation/test event is not persisted as a customer event | Candidate MailerSend signature and non-persistence contracts |
| NS-13 | Unmatched then matched provider event | Unmatched event remains retryable; later exact attempt correlation reconciles once | Candidate provider-event reconciliation SQL contracts; stage with synthetic signed fixture |
| NS-14 | Duplicate signed provider event | Idempotent no-op; suppression and attempt state do not duplicate | Candidate event uniqueness/suppression contracts |
| NS-15 | Execution data inspection | No recipient, message body, Shopify token, provider token, fingerprint secret, or delivery authorization token in n8n inputs/outputs/errors | Adapter/runtime redaction tests; live n8n retention and redaction remain unverified |

### Acceptance exit criteria

No-send acceptance is **not complete** until all of the following are attached to one immutable test run:

1. Every NS-01 through NS-15 case has a named test, result, and evidence reference.
2. The complete composed Recovery → Delivery harness intercepts all outbound requests and fails on any MailerSend hostname or unapproved destination.
3. Both checkout and pixel branches are exercised, including empty batches and mixed/invalid claim batches.
4. Disposable database fixtures prove exact-store isolation, concurrent lease behavior, stale-lease rejection, consent/suppression, sender, provider readiness, cost cap, uninstall stop, and ambiguous-attempt reconciliation.
5. The test run inspects serialized inputs, outputs, logs, and thrown-error surfaces for sensitive-field leakage.
6. All tests run against the exact PR head being reviewed; no result from an earlier commit is carried forward as if it validates a later head.

A green adapter suite alone is insufficient. A green SQL suite alone is insufficient. Both must be linked to the same candidate SHA.

## 4. Controlled staging plan

Staging is a separate, isolated environment. Do not use production as a staging target and do not copy live customer PII into synthetic fixtures.

### Stage 0 — identify and freeze the staging boundary

Required before any deployment action:

- Name the owner-controlled staging Supabase project, Cloudflare account/Worker route, Shopify development store/app, n8n staging workspace/instance, and MailerSend test account or stub.
- Verify each target is separate from production by project ID, hostname, app/client ID, workflow IDs, credential namespace, and provider account.
- Use synthetic stores, customers, checkouts, consent evidence, orders, provider events, and tokens.
- If no separate n8n staging instance/workspace exists, keep the work at offline tests; do not import drafts into the three live workflows.
- Read-only Supabase inventory on 20 November found the active `henvalt` project (`ocyplckdojdubyrsxcxa`) and the older `henvalt_v23` project (`wrsediuhepdyajnihjoz`) in `INACTIVE` status. Prior project history says preserve the active project and do not start a new project or rebuild the database. Therefore `henvalt_v23` is **not** treated as a staging target and must not be restored/reactivated as part of this plan.
- If no zero-cost staging project exists, use disposable PostgreSQL in CI and stop. Do not create a paid project, branch, or subscription under this plan.
- Capture names and presence of staging secrets only; never place secret values in Git, documents, or test output.

**Exit:** all staging targets are owner-controlled and demonstrably distinct from production, or the staging exercise remains CI-only.

### Stage 1 — database rehearsal

- Start from a synthetic PostgreSQL 17 baseline, not a production database dump.
- Apply candidate migrations 001–060 in order.
- Run the complete SQL lifecycle, exact-store isolation, concurrency, privacy, cost-reservation, attribution, and recovery-claim fixtures.
- Record migration timings, lock observations, object counts, grants, RLS policies, triggers, indexes, constraints, and RPC signatures.
- Confirm the test runner destroys the disposable database after evidence capture.
- Do not apply migrations to production or merge the candidate chain.

**Exit:** all migrations and database contracts pass on the exact candidate SHA; no unexplained schema drift or cross-store row access.

### Stage 2 — Edge Function staging

Only after Stage 0 and Stage 1 pass:

- Deploy candidate Edge Functions to a dedicated staging Supabase project, never to the production project.
- Use staging-only app identity, Vault references, service credentials, checkout/pixel delivery bearer tokens, and synthetic provider configuration.
- Keep delivery readiness false and provider transport stubbed/blocked.
- Verify unauthenticated requests, wrong-store IDs, missing credentials, inactive app/connection, consent denial, suppression, exhausted cap, and malformed requests all fail closed.
- Verify logs and responses contain no PII, message body, or secret values.

**Exit:** health/configuration checks and negative authorization cases pass; provider transport remains impossible.

### Stage 3 — Worker and Shopify ingress staging

- Use a separate Worker test route and staging-only route tokens.
- Verify raw-body Shopify HMAC, wrong-shop signature, duplicate delivery, replay, invalid route token, and exact-store receipt behavior.
- Use a staging-owned Shopify development app/store only.
- Do not alter the production app, production callback, or production webhook subscriptions.
- If a paid-plan payment capability is unavailable, mark paid-order/refund acceptance blocked; do not purchase or fabricate a paid order.

**Exit:** one authoritative staging ingress, idempotent exact-store receipts, and no production route overlap.

### Stage 4 — n8n staging rehearsal

- Preserve exactly the three logical responsibilities: Ingest, Recovery, Delivery.
- Import reviewed changes only into a separate staging n8n instance/workspace as inactive drafts.
- Do not create a fourth workflow and do not import into or edit the live production workflows.
- Recovery owns claim finishing; Delivery only validates/routes/classifies opaque work.
- Confirm execution retention/redaction settings and inspect complete execution data.
- Disable legacy/V2 overlap in the staging graph so one event and one opportunity have exactly one processing path.
- Use the stubbed provider transport. A workflow run must be incapable of reaching MailerSend.

**Exit:** all NS cases pass in the composed staging runtime; execution data is demonstrably free of protected fields.

### Stage 5 — provider event rehearsal without customer delivery

- Use synthetic signed MailerSend test events and a stubbed provider boundary.
- Preserve original raw bytes and signature header.
- Test URL validation, unmatched event retry, matched event reconciliation, duplicate event idempotency, unsubscribe, complaint, and hard-bounce suppression.
- Do not change the production MailerSend event destination or readiness flag.
- Do not submit customer email or real provider messages.

**Exit:** signature, idempotency, reconciliation, and suppression contracts pass with zero real provider submissions.

### Stage 6 — staging acceptance report

The report must contain:

- Exact candidate SHA and CI run IDs.
- Staging target identifiers (non-secret IDs only).
- NS-01–NS-15 results and links.
- Migration and database contract results.
- Shopify ingress and exact-store isolation evidence.
- n8n workflow export hashes, inactive status, execution-retention/redaction evidence.
- Provider stub call count = 0 real MailerSend requests.
- Defects, unresolved blockers, owner, and remediation.
- Explicit statement that no production system, customer, or billing state was changed.

**Exit:** engineering review signs the staging report. This does not authorize production.

## 5. Production gates remain separate

Even after staging passes, production remains HOLD until separately approved evidence exists for:

- Owner-controlled Shopify Partner app and public app identity, callback, scopes, protected customer data, and Pixel UID.
- Production Supabase schema/migration parity, historical exact-store lineage dispositions, verified backup restore, and production-like clone rehearsal.
- Owner-controlled Cloudflare Worker and Edge Function secrets/routes.
- The three production n8n workflow exports, duplicate-ingress prevention, manual one-off sender branch removal, and execution retention/redaction.
- MailerSend sender/domain, API permissions, signed V2 event destination, event-set verification, and merchant-funded cost cap.
- Privacy export/redaction completion evidence and incident/rollback procedures.
- A controlled, consent-eligible test-store lifecycle proving provider event, paid-order attribution, refunds, and non-charging fee measurement.
- Separate written approvals for production migration, Edge/Worker deployment, workflow cutover, provider event routing, customer sends, billing, Shopify release, and rollout.

No stage approval implies approval of the next stage.

## 7. Latest no-send evidence — 20 November 2026

Candidate commit: `5180c9fa36ff9811081a4659faa190ce24f439f9`.

Exact-SHA GitHub Actions:
- Identity V2 validation: run `44735254457` — **success**.
- Shopify app configuration checks and deployment workflow: run `44735254265` — **success**. This workflow's successful status is CI evidence only; no production release or deployment is authorized by this plan.
- Identity V2 log records repository Node regression suite **459/459**, focused provider/uninstall suite **13/13**, and identity/cost/privacy suite **228/228**. These are separately reported suite totals, not additive unique test counts.
- Disposable PostgreSQL candidate migration and SQL lifecycle steps completed in the Identity V2 run. This is CI-only evidence and does not establish production schema parity or a staging deployment.

Additional tests on this candidate:
- Checkout delivery endpoint-specific bearer authentication is asserted to precede readiness checks, request parsing, and the first tenant/store lookup.
- Pixel delivery endpoint-specific bearer authentication is asserted to precede readiness checks, request parsing, and the first tenant/store lookup.
- These are source-order regression tests. They do **not** constitute runtime composed wrong-store or missing-auth acceptance tests, nor do they prove actual staging Edge Function behavior.

Acceptance remains **PARTIAL**: NS-06 wrong-store and missing-auth composed cases remain open; full NS-01–NS-15 composed runtime acceptance and isolated staging execution remain open. Production remains **HOLD**.

## 6. Current decision

**NO-SEND ACCEPTANCE: PARTIAL — latest exact-SHA CI on candidate `71deb1b5cd26f8d8d23eecac937782a0148e7e5a` passes 464/464 repository Node tests, including the four new checkout/pixel exact-lineage and fail-closed source-contract tests. The Identity V2 workflow and Shopify app configuration workflow both pass. This remains source/CI evidence, not composed runtime wrong-store/missing-auth acceptance. Full NS-01–NS-15 composed acceptance and live n8n redaction evidence remain open.**

**STAGING PLAN: PREPARED — execution is blocked until an owner-controlled, isolated, zero-cost staging boundary is identified.**

**PRODUCTION: HOLD — no production operation is authorized by this document.**


## 8. Latest no-send evidence — 20 November 2026, 17:54 PKT

Candidate code commit: `85053cd866f4adbc1b11f403b5c2d21bbc12a7e8`.

Exact-SHA GitHub Actions:
- Identity V2 validation: run [44736568217](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44736568217) — **success**.
- Shopify app configuration checks and deployment workflow: run [44736568036](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44736568036) — **success**; no production deployment was performed or authorized.
- Identity V2 job totals: repository Node regression **460/460**, focused provider/uninstall **13/13**, identity/cost/privacy **229/229**. These are separately reported suite totals, not additive unique test counts.
- Disposable PostgreSQL checkout provider-submission gate printed `shopify_checkout_provider_submission_gate_passed`.
- Disposable PostgreSQL pixel provider-submission gate printed `shopify_pixel_provider_submission_gate_passed`.
- The prior run on `8fecfd0` failed because the newly registered pixel SQL step did not receive the disposable database password. Commit `85053cd` explicitly supplies `PGPASSWORD`; the exact-SHA rerun above completed successfully and both provider gate SQL tests passed.

This evidence is limited to candidate CI and disposable PostgreSQL. It does not validate production schema parity, deployed Edge Functions, real provider behavior, or a staging environment.

PR #6 remains **OPEN, DRAFT, UNMERGED**. No merge, deployment, workflow activation, customer send, or billing action occurred.

Acceptance remains **PARTIAL**: composed wrong-store and missing-auth runtime cases remain open; full NS-01–NS-15 composed acceptance, live n8n execution-data redaction evidence, and isolated staging execution remain open. Production remains **HOLD**.


## 9. Latest exact-head validation — 20 November 2026, 18:37 PKT

Candidate code commit: `71deb1b5cd26f8d8d23eecac937782a0148e7e5a`.

Exact-SHA GitHub Actions:
- Identity V2 validation: run [44745375330](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44745375330) — **success**.
- Shopify app configuration checks and deployment workflow: run [44745375444](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44745375444) — **success**; the workflow result does not authorize or imply production deployment.
- Identity V2 repository Node regression suite: **464/464 passed**, zero failures.
- The following new source-contract tests passed: checkout final-gate tenant/store lineage; checkout missing/incorrect dedicated bearer and disabled-send interlock ordering; pixel opportunity/customer/tenant/store lineage; pixel missing/incorrect dedicated bearer and disabled-send interlock ordering.
- The immediately preceding commit `52fe62cf441f74f28efd8abfdae60e85bc49b2b5` had one failing checkout test expectation because the test expected `delivery_not_configured` while the implementation contract returns `delivery_configuration_missing`. The assertion was corrected in `71deb1b`; the exact-head rerun passed.

This is static/source-contract plus CI evidence. It does not prove composed runtime wrong-store/missing-auth behavior, deployed Edge Function behavior, provider transport blocking in staging, or n8n execution-data redaction.

PR #6 remains **OPEN, DRAFT, UNMERGED**. No merge, deployment, production mutation, workflow activation, customer send, or billing action occurred.

Acceptance remains **PARTIAL**. NS-06 composed wrong-store and missing-auth runtime cases, the full NS-01–NS-15 composed run, live n8n retention/redaction evidence, and isolated staging execution remain open. Production remains **HOLD**.
