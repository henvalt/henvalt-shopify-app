# HENVALT 48-hour system readiness baseline
**Observed:** 2026-11-21  
**Purpose:** Parallel engineering baseline for a controlled no-send cutover and isolated staging candidate.  
**Safety:** Read-only production inspection. No production SQL writes, n8n workflow edits, Edge Function deployments, Shopify releases, provider sends, billing changes, or merges were performed.

## Executive status

HENVALT has substantial working infrastructure, but the live system is not yet a verified no-send staging candidate. The three legacy n8n workflows are active. The delivery graph has an authenticated internal delivery webhook and a separate manual one-off test-send path. The current database authorization path enforces many per-tenant and per-message checks, but the inspected live `authorize_delivery_request` function has no explicit global sender interlock. The live `get_mailersend_token_for_delivery` function also contains a narrowly scoped hard-coded one-off test exception. This is a release blocker until the candidate path has one consistent, independently verified stop control across every send entry point.

## Live system baseline

### GitHub
- Repository: `henvalt/henvalt-shopify-app`
- Default branch: `main`
- Main head observed: `04ab46059543f2d577370a229e38a7475579fe59`
- Existing draft PRs: #1, #2, #4, #5, #6.
- PR #6 is a large draft preparation branch (1,742 commits in PR metadata); it is not merged.
- PR #6 body reports a historical full candidate validation at `36ddc84ffd0f8396887797fb4c4a9f146ea49273`; its current head is `52bdb496177e2f442289ea1534063858504e9fbe`. The connected combined-status query for the current head returned no status entries. Do not treat historical CI as current-head verification.
- A new documentation-only engineering branch was created from `main`: `work/48h-system-readiness-2026-11-21`.

### Supabase production
- Connected active project: `ocyplckdojdubyrsxcxa` (`henvalt`), PostgreSQL 17.6.1.
- Migration history: 178 entries; latest applied migration `20261114174204`.
- Current read-only data counts: 3 tenants, 4 Shopify connections, 166 canonical events, 5 opportunities, 5 recovery interventions, 3 delivery requests, 5 delivery attempts, 0 orders, 0 order attributions, 0 revenue-ledger rows.
- All three tenants are ACTIVE. These counts are a point-in-time operational snapshot, not proof of merchant-ready end-to-end recovery.
- Live Edge Functions include the legacy control plane, dashboard, OAuth, privacy, merchant dashboard/settings, and MailerSend delivery functions. The live inventory does not prove candidate V2 functions are deployed.
- Security advisor findings: 11 RLS-enabled internal tables without client policies (currently fail closed; do not add broad policies), one authenticated-executable SECURITY DEFINER membership helper requiring deliberate review, and leaked-password protection disabled.
- Performance advisor: one unindexed tenant foreign key on `henvalt.shopify_privacy_requests`; numerous unused-index notices should not trigger index deletion before real traffic.

### n8n production
All three workflows are active:
- `HENVALT_INGEST` — 51 nodes, active version `6368d539-708f-494a-8be8-b9601d0e8607`.
- `HENVALT_RECOVERY` — 46 nodes, active version `32e50bf7-4cbd-4070-bbba-f259ed17b369`.
- `HENVALT_DELIVERY` — 62 nodes, active version `621ae6ce-a006-4fed-a70e-acf774c360fb`, seven webhook/manual trigger routes.

Observed recovery execution `40601` succeeded as an orchestration run, but the actual node data showed:
- Browse, cart and checkout discovery each returned zero newly queued/created items.
- Deferred payment reconciliation returned zero work.
- Stale-work repair returned zero requeues/recoveries.
- The worker claim returned no job; `has_job=false`.
Therefore, green scheduler executions currently mean the polling cycle ran successfully, not that an abandonment was recovered or an email was delivered.

The delivery workflow includes:
- Internal delivery webhook -> request normalization -> Supabase `authorize_delivery_request` -> `can_send` gate -> MailerSend Edge Function.
- Separate manual one-off test delivery route -> test-only authorization gate -> same MailerSend Edge Function.
- Tracking, unsubscribe, provider event and inbound-reply webhook routes.

A recent inspected MailerSend event execution was signature-verified and accepted as a provider event. That proves the legacy event-ingestion path worked for that event; it does not establish a safe global send stop.

## Critical safety findings

1. **No global sender interlock was found in the inspected live send authorization path.** `authorize_delivery_request` checks tenant status, request identity/status/due time, intervention and sequence state, opportunity eligibility, per-tenant `recoveryEnabled` and flow flags, Shopify connection, paid-order suppression, communication eligibility/consent, email suppressions, message/unsubscribe readiness, sender identity and provider configuration. These are valuable controls, but they are not a single global no-send interlock.
2. **The provider-token RPC contains a hard-coded one-off test exception.** It is scoped to a specific test-only delivery identity, but it is still an alternate authorization branch that must be explicitly fenced or removed in the candidate interlock design.
3. **The n8n delivery workflow has a distinct manual one-off send route.** A no-send acceptance test must prove this route is blocked too, not only the ordinary recovery route.
4. **All legacy workflows remain active.** Do not deactivate the entire delivery workflow blindly: it also serves unsubscribe, tracking, provider-event and inbound-reply routes. A stop should block provider-send capability without breaking compliance and tracking endpoints.
5. **Execution-data retention/redaction is not yet independently verified.** Execution data can contain personal/customer and message context. Obtain runtime settings/evidence and verify retention/purge behavior before staging acceptance.
6. **The live production schema is behind the V2 candidate branch.** Production has 178 migrations through 14 November; candidate V2 migrations and Edge Functions must remain isolated until separately approved.

## Parallel 48-hour workstreams

### A. Safety and send interlock
- Design one server-side deny-by-default interlock checked by every provider-send authorization route, including ordinary delivery and one-off test delivery.
- Preserve unsubscribe, tracking, privacy, MailerSend event and inbound routes.
- Add an auditable state/reason and a fail-closed default.
- Add negative tests for every entry point and prove no provider token is released while stopped.
- Do not deploy to production without explicit approval.

### B. Shopify and event ingestion
- Reconcile main vs draft candidate PRs and exact-store identity lineage.
- Verify OAuth state/HMAC, webhook HMAC, duplicate delivery, uninstall deactivation, privacy topics and Web Pixel origin/consent.
- Keep anonymous pixel events isolated from customer identity and email eligibility.
- Do not release a Shopify app version during this preparation pass.

### C. Supabase data and privacy
- Reconcile candidate migrations against the 178-migration live baseline.
- Verify tenant isolation, consent revocation, suppressions, order/refund attribution, and billing measurement invariants.
- Inspect retention/export/redaction RPCs and purge evidence.
- Review the membership helper warning without breaking dependent RLS policies.
- Do not apply production DDL during the no-send preparation stage.

### D. n8n orchestration
- Inspect all three active workflow graphs and execution settings.
- Validate claim/lease/idempotency and stale-job recovery.
- Verify each of the three workflows against the intended V1 contract.
- Prove the ordinary and manual test delivery branches are blocked by the interlock.
- Keep non-send compliance routes functional.

### E. Dashboard and billing
- Verify dashboard authentication, exactly-one active membership/connection assumptions, and tenant-scoped read models.
- Reconcile dashboard metrics against confirmed attribution and revenue-ledger rows only.
- Keep billing read-only until recovered revenue attribution is independently verified.
- Do not represent empty ledger/order counts as recovered revenue.

### F. Release acceptance
- Run the full acceptance matrix against isolated staging.
- Capture exact commit, migration set, workflow version IDs, Edge Function versions, test outputs and rollback evidence.
- Require explicit owner go/no-go before any production change or customer send.

## Go/no-go criteria

Staging may be considered a candidate only after:
- The sender interlock is present in the candidate and proven to deny every send entry point.
- The test-only exception is either removed or explicitly governed by the same stop.
- No customer/provider send is possible during no-send acceptance.
- Ingest, privacy, unsubscribe, tracking and provider-event routes still pass their tests.
- Tenant isolation, consent/suppression, idempotency and attribution tests pass.
- Retention/redaction evidence is captured.
- Exact-head CI and disposable database integration tests pass on the same commit being reviewed.
- A rollback plan and evidence bundle are complete.

**Production remains untouched until explicit approval.**
