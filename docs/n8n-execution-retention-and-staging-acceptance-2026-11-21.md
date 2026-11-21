# n8n execution-data retention and staging acceptance
**Prepared:** 2026-11-21  
**Scope:** Read-only production workflow inspection and candidate staging procedure.  
**Change boundary:** This document is committed only to `work/48h-system-readiness-2026-11-21`. No live workflow, instance setting, execution record, credential, database object, Worker, Edge Function, Shopify app version, or provider setting was changed.

## 1. Verified live workflow inventory

The connected n8n instance returned exactly three HENVALT workflows:

| Workflow | ID | Active version | Nodes | Triggers | Active |
|---|---|---|---:|---:|---|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 | 1 | yes |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 | 1 | yes |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 | 7 | yes |

All three currently report only workflow-level settings for execution order, binary mode, saved-time mode, caller policy and MCP visibility. No per-workflow execution-pruning or execution-redaction policy was exposed in the retrieved workflow settings. Do not infer that instance-wide pruning is disabled solely from this absence.

## 2. Delivery route inventory and stop-control coverage

The active delivery graph has two distinct provider-send nodes:

1. **Ordinary delivery:** `Internal Delivery Webhook` → `Validate & Normalize` → `Authorize & Context` → `Cleared to Send?` → `MailerSend Send`.
2. **Manual one-off test:** `One-Off Test Email Trigger` → `Prepare One-Off Test Delivery` → `One-Off Test Authorized?` → `MailerSend One-Off Test Email`.

Both provider nodes call the same Supabase `henvalt-mailersend-delivery` Edge Function. The provider-token RPC is the credential-release boundary. The candidate global interlock migration is designed to block the database transition that releases a provider credential, including the legacy test exception. This is a design claim backed by candidate PostgreSQL tests, not a live production control.

The following routes must remain functional while provider sends are stopped:
- Tracking-link resolution and explicit checkout confirmation.
- GET and RFC 8058 POST unsubscribe.
- Signed MailerSend event ingestion.
- Signed inbound-reply ingestion and reply-state handling.
- Shopify ingest, privacy processing and recovery bookkeeping.

**Do not deactivate the entire HENVALT_DELIVERY workflow as a kill switch.** Doing so would also disable compliance and event routes. A safe stop is enforced at the shared provider authorization/credential-release boundary.

## 3. Execution-data retention finding

A historical delivery execution (`31260`, 2026-11-14) remained retrievable on 2026-11-21. Its stored node payload included recipient, subject, HTML body and tracking/unsubscribe URLs. Runtime metadata reported both production and manual redaction flags as false. This proves sensitive delivery content remained readable for at least seven days; it does not prove the configured maximum age or that every execution is retained indefinitely.

The connected n8n API used for this inspection exposes workflow and execution reads, but did not expose instance-level pruning/redaction configuration. Therefore the effective retention policy is **unverified** and staging acceptance is blocked until an owner/admin provides evidence.

### Required owner/admin evidence

Capture, without copying secrets or customer payloads:
- n8n plan/deployment type and instance version.
- Effective execution-data pruning enabled/disabled state.
- Effective maximum execution age and maximum-count policy.
- Save-on-success, save-on-error and save-manual-execution policies.
- Whether production and manual execution redaction are enabled and effective.
- Whether binary execution data follows the same pruning policy.
- Whether pruning is running successfully, with a timestamped admin screenshot or supported API/config evidence.
- Who can view execution history and whether project/role access is restricted.

Do not guess environment variables or assume a hosted plan exposes self-hosted settings. If the plan does not permit the required controls, document that limitation and use a supported owner-level retention feature or move sensitive payload processing to a separately controlled runtime before launch.

### Retention acceptance

1. Define a written retention period with the data owner and privacy requirements; distinguish successful, failed and manual executions.
2. Prefer not to persist successful execution payloads when operationally unnecessary. For failures, retain only the minimum diagnostic context needed; avoid recipient addresses, message bodies, tokens, authorization headers and full webhook payloads.
3. If n8n cannot redact selected fields, do not claim redaction. Minimize upstream node output and avoid returning sensitive payloads into execution data where possible.
4. Verify pruning with a non-sensitive synthetic staging execution and confirm it becomes inaccessible after the configured age.
5. Verify error/manual paths independently; a successful-execution policy does not prove error/manual data is protected.
6. Preserve a separate, access-controlled audit record containing execution ID, workflow ID/version, timestamp, outcome class and correlation ID only. Do not copy customer content into the audit record.
7. Do not bulk-delete production history until retention policy, legal hold and incident-evidence requirements are approved.

## 4. No-send staging acceptance matrix

Run only in an isolated staging environment with test credentials, a provider stub or network-denied egress. Never use the production MailerSend credential for negative tests.

| Test | Expected result | Evidence |
|---|---|---|
| Global interlock absent/unconfigured | Deny by default | DB assertion and audit reason |
| Ordinary delivery while interlock closed | No provider token; no provider request | Request state, no credential claim, stub request count = 0 |
| Manual one-off test while interlock closed | No provider token; no provider request | Same assertions for the exact one-off route |
| Attempt to change interlock as app/service client | Permission denied | Role/ACL assertion |
| Authorized operator opens/closes interlock | Append-only audit entry with actor, reason and timestamp | Audit row and state transition |
| Interlock state unavailable / RPC timeout | Fail closed | Simulated database/RPC failure |
| Tracking route while interlock closed | Tracking still works | Valid synthetic token resolves safely |
| Unsubscribe GET/POST while interlock closed | Consent revocation still works | Synthetic customer state + audit |
| Signed provider event while interlock closed | Event accepted idempotently | Signature result and deduplication record |
| Signed inbound reply while interlock closed | Reply recorded; send remains blocked | Inbound event state and zero send count |
| Duplicate delivery request | Idempotent; no duplicate provider request | One claim and one stub call at most |
| Tenant A request with Tenant B identifiers | Denied | No cross-tenant read/write |
| Analytics/marketing/email consent denied | No browse recovery send | Candidate suppression result |
| Order paid/cancelled or customer unsubscribed | No recovery send | Authorization reason |
| Provider stub timeout after request | Ambiguous state; no blind resend | Idempotency and retry-state evidence |

A passing database trigger test alone is insufficient. The test must exercise both exact n8n send routes and verify the provider stub received zero calls while the interlock is closed.

## 5. Staging execution sequence

1. Provision/identify an approved isolated Supabase staging project and isolated n8n project/runtime. Do not reuse production credentials, provider tokens, webhook secrets or customer data.
2. Record exact Git commit, migration hashes, Edge Function source hashes, Worker version, n8n workflow version IDs and Shopify app version.
3. Apply candidate migrations only to staging, in order; run the disposable PostgreSQL suite and then the full schema-aware staging suite.
4. Deploy candidate Edge Functions/Worker only to staging and verify their environment bindings point exclusively to staging.
5. Keep provider egress denied or replace MailerSend with a deterministic stub.
6. Import/copy the three workflows as staging copies; confirm all outbound HTTP destinations and credentials resolve to staging/stub endpoints before enabling any trigger.
7. Run the no-send matrix above, then ingest synthetic Shopify webhook/pixel events and test tenant isolation, consent, unsubscribe, order suppression and attribution.
8. Test one explicit positive provider-stub case only after the no-send tests pass; assert exactly one idempotent stub request and no real provider traffic.
9. Verify dashboard recovered-order and revenue metrics from confirmed synthetic attribution/ledger fixtures only.
10. Capture retention/pruning evidence and rollback artifacts.
11. Keep the candidate NO-GO until the owner explicitly approves the production cutover. Passing staging does not itself authorize production changes.

## 6. Release blockers and ownership

| Blocker | Required proof | Status |
|---|---|---|
| Live global provider stop | Approved deployment + independent route-level verification | Not installed in production; intentional |
| Exact ordinary/manual no-send route tests | Isolated n8n tests with network-denied provider stub | Not yet evidenced |
| n8n execution retention/redaction | Owner/admin settings + synthetic expiry test | Unverified |
| Isolated Supabase staging | Approved healthy project with candidate schema | Not identified |
| Shopify OAuth/webhook/pixel E2E | Fresh test-store event reaches staging canonical event | Not evidenced |
| Confirmed recovery attribution | Synthetic staging order → confirmed attribution → ledger | Not evidenced end-to-end |
| Production cutover approval | Explicit owner go/no-go | Not granted |

## 7. Safety conclusion

The live n8n delivery workflow contains a real ordinary send route and a real manual one-off send route. Both converge on the same provider Edge Function, but production does not yet have the candidate global interlock. The historical execution proves sensitive email content remained available in execution history for at least seven days, while effective retention/redaction settings remain unknown.

**Current decision: NO-GO for production release.** Keep production workflows, database, Worker, Edge Functions, Shopify app version and provider credentials unchanged until isolated staging passes the complete acceptance matrix and the owner explicitly approves the cutover.

## 8. Fresh operational snapshot — 2026-11-21 06:11 UTC

A read-only inspection of recovery execution `40663` confirmed that the every-minute schedule completed successfully in about two seconds, but performed no recovery work:

- Deferred payment reconciliation: retried 0, skipped 0, processed 0, dead-lettered 0.
- Stale-work repair: requeued 0 jobs and recovered 0 interventions.
- Shopify token due query: returned no items.
- Browse discovery: queued 0 and created 0; 60-minute inactivity threshold; 0 explicitly counted as suppressed/ineligible.
- Worker claim returned no job (`has_job=false`).
- Abandoned-cart discovery: queued 0, created 0, refreshed 0.
- Abandoned-checkout discovery: queued 0, created 0, refreshed 0.

This is a successful **idle/no-op scheduler run**, not evidence of a functioning end-to-end recovery. In particular, it does not prove that Shopify events are arriving, opportunities are being created, delivery requests are being claimed, or emails are being sent.

The latest delivery-workflow execution returned by the connected execution search was `31277` on 2026-11-14. Inspecting it showed the **MailerSend Events Webhook** route: a signed `activity.opened` provider event was verified and matched to a delivery request. It was not an outbound send execution. No outbound-send execution was evidenced in the returned recent delivery history; do not interpret this limited query as proof that no provider sends occurred outside the returned history.

The latest returned ingest webhook executions were also dated 2026-11-14. Therefore fresh Shopify-to-ingest traffic has not been evidenced in this read-only sample.

### Immediate staging diagnosis gates

Before attempting to enable any staging sender, prove each boundary independently:

1. Shopify webhook/pixel request reaches the intended staging ingress and passes signature/consent validation.
2. Ingest workflow creates exactly one tenant-scoped canonical event (and duplicate replay creates none).
3. Recovery discovery creates the expected opportunity/intervention from a synthetic eligible event.
4. Recovery worker claims the expected job and produces a delivery request with stable idempotency/correlation IDs.
5. Delivery authorization independently checks tenant, order suppression, communication permissions and unsubscribe state.
6. With global interlock closed, both normal and manual routes stop before credential release; provider stub request count remains zero.
7. With staging-only interlock explicitly opened for one positive test, the stub receives exactly one request and no real MailerSend egress occurs.
8. A synthetic Shopify paid-order webhook confirms attribution and revenue ledger exactly once; dashboard then reflects the confirmed order, not value-at-risk.

Until these are demonstrated, the observed recovery scheduler heartbeat must remain classified as **operational but not commercially verified**.

## 9. Updated candidate CI and preview evidence

After this runbook commit, GitHub Actions run `44873237209` completed successfully: static safety/consent checks, all four candidate migrations against disposable PostgreSQL 17, and the deny/allow/audit/fail-closed acceptance SQL all passed. The Shopify configuration workflow `44873237133` also passed static validation; its Shopify deployment job was skipped.

Cloudflare Pages generated branch-preview deployments for commit `3d72b9e` on both dashboard Pages projects. These are preview builds only; no production Worker, Edge Function or Shopify app version was deployed.

These CI and preview results strengthen candidate evidence but do not replace the missing full-schema isolated staging and real Shopify event chain.


## 10. Sanitized active delivery-route snapshot — 2026-11-21

A second read-only inspection captured the active `HENVALT_DELIVERY` graph topology and pinned active version `621ae6ce-a006-4fed-a70e-acf774c360fb`. The sanitized snapshot is stored at `tests/fixtures/n8n-delivery-route-snapshot.json` and checked by `tests/n8n-delivery-route-snapshot.test.mjs` in CI.

The snapshot records two separate outbound provider entry points:

- Ordinary: `Internal Delivery Webhook` → `Validate & Normalize` → `Precheck Valid?` → `Authorize & Context` → `Cleared to Send?` → `Build Reply-To Address` → `MailerSend Send`.
- Manual one-off: `One-Off Test Email Trigger` → `Prepare One-Off Test Delivery` → `One-Off Test Authorized?` → `MailerSend One-Off Test Email`.

Both provider nodes issue POST requests to the same function slug, `henvalt-mailersend-delivery`. The fixture intentionally excludes endpoint hostnames, credentials, request payloads and customer data.

This CI test is a **route-topology regression guard**, not a live n8n query and not evidence that the stop control is installed or that either route is blocked. A live route can change without this fixture changing; refresh the snapshot after any approved workflow-version change. Staging still requires independent tests of both routes against provider egress denied, asserting zero provider-stub calls and no token release.

**Production remains NO-GO.** No live workflow was changed, no sender was disabled or enabled, and no provider request was generated during this inspection.
