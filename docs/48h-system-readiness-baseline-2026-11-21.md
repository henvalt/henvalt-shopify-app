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


## Final-day live refresh — 2026-11-21 05:16 UTC

Additional read-only checks were completed after the initial baseline.

### Recovery worker, current production activity
- Latest inspected scheduler execution: `40607`, 2026-11-21 05:15:28 UTC; status `success`.
- `Discover Browse Abandonment`: `queued=0, created=0`.
- `Discover Abandoned Cart`: `queued=0, created=0`.
- `Discover Abandoned Checkout`: `queued=0, created=0`.
- `Claim Due Job`: returned no job.
- `Repair Stale Work`: `requeued_jobs=0, recovered_interventions=0`.
- `Find Shopify Tokens Due`: no token was due at 05:15 UTC. The query refreshes tokens when access expiry is within 10 minutes.
- The recovery scheduler is running every minute; green scheduler runs must not be represented as successful merchant recovery.

### Shopify token lifecycle
- The current expiring-offline-token connection is `ur4jvw-nz.myshopify.com`.
- At 05:16:03 UTC, its access token was due to expire at 05:58:28 UTC and its refresh token at 2027-02-19 04:58:29 UTC.
- The active recovery workflow contains `Find Shopify Tokens Due` and `Refresh Shopify Offline Token`, which call the active `henvalt-shopify-token-refresh` Edge Function. The refresh threshold is 10 minutes before access-token expiry.
- The database has only one active pg_cron job, the 15-minute privacy-export purge. Shopify token refresh is orchestrated by the n8n minute worker, not pg_cron.
- Continue observing the next scheduled refresh window; do not force a production token refresh as a test.

### Pixel ingestion lineage
- Production has 16 pixel keys, of which 1 is active and not revoked.
- The deployed `henvalt-pixel-ingest-proxy` Edge Function (version 3) forwards to the existing authenticated `public.henvalt_ingest_pixel_event(text,text,text,jsonb)` RPC, which verifies the collector secret and delegates to `henvalt.ingest_pixel_event`.
- The repository migration `202611160008_shopify_pixel_event_inbox_v2.sql` is not applied in the connected production project: migration history still ends at `20261114174204`, and the V2 inbox table is absent.
- Therefore the V2 exact-install inbox is candidate code, not live production capability. Do not describe the V2 adapter or browse event pipeline as deployed.

### Webhook / delivery evidence freshness
- The latest listed `HENVALT_INGEST` executions are from 2026-11-14; the latest listed `HENVALT_DELIVERY` executions are also from 2026-11-14.
- The n8n recovery scheduler is active today, but there is no fresh end-to-end Shopify webhook-to-delivery acceptance evidence today.
- No synthetic Shopify webhook should be sent to production without explicit approval because it writes production event state.

### Revised immediate priorities
1. Run the static interlock tests on PR #7 and obtain a current-head result.
2. Validate the candidate migration syntax in a disposable staging database; do not apply it to production.
3. Verify the n8n token refresh when the current access token enters the 10-minute refresh window, using the existing scheduler's normal path.
4. Validate the existing pixel proxy/RPC path in isolated staging; keep the V2 inbox migration explicitly separate.
5. Build a real end-to-end Shopify webhook test in staging with synthetic payloads and isolated credentials.
6. Finish delivery no-send negative tests, including manual one-off test send, and preserve non-send compliance endpoints.

**Current go/no-go:** NO-GO for production release. The interlock is candidate code only; the V2 pixel inbox is unapplied; no fresh webhook-to-revenue acceptance exists; and staging runtime tests are not yet evidenced.


### Dashboard and merchant-control plane
- The live `henvalt-merchant-dashboard` Edge Function validates the bearer token through Supabase Auth; it does not trust decoded JWT claims.
- It requires exactly one tenant membership and exactly one active Shopify connection belonging to an ACTIVE tenant.
- Dashboard revenue rows are read only from `revenue_ledger` with `entry_type = RECOVERY` and `attribution_confidence = CONFIRMED`; this is the correct source of truth for recovered revenue.
- The UI explicitly renders empty states and does not substitute sample metrics. Current live data has zero orders, zero confirmed attributions and zero revenue-ledger entries, so there is no verified recovered revenue to display.
- `henvalt-merchant-recovery-settings` turns global recovery off before applying flow changes, then turns it back on only when requested. This is a useful tenant-level control but is not a replacement for the global provider-send interlock.

### Delivery-route coverage confirmation
- Both ordinary `MailerSend Send` and manual `MailerSend One-Off Test Email` nodes call the same `henvalt-mailersend-delivery` Edge Function.
- The manual test path first calls `reauthorize_one_off_test_delivery`; the original test path calls `prepare_one_off_test_delivery`. Both ultimately pass through the delivery request authorization and the same provider-token RPC.
- The candidate database trigger therefore guards the two observed n8n send routes at the database claim/credential-release boundary. The staging test must still exercise both exact routes, and all future send paths must use the same protected Edge Function/RPC.


### Historical manual-send proof (critical)
- Read-only inspection of n8n execution `31260` (2026-11-14 17:42 UTC) confirms the manual one-off test route reached `henvalt-mailersend-delivery`.
- MailerSend returned HTTP `202 Accepted`; the provider event subsequently recorded HTTP `200` / `DELIVERED` for that same provider message ID.
- The corresponding production delivery request is now in `DELIVERED` state. It has one initial credential-unavailable failure, then one provider-accepted attempt, followed by the delivered provider event.
- This proves the manual one-off route was a real production send path, not merely a preview. Tenant recovery flags being false do not provide a global stop because the one-off test authorizer temporarily enables its narrowly allowlisted test flow inside its transaction.
- Consequently, **production is not independently proven no-send** until the global interlock (or an equivalent approved production stop) is installed and every route is verified. No stop was installed during this session.

### Production stop-state snapshot
- All three tenant records currently report `recovery_enabled = false`; configured recovery flow entries are disabled where present.
- This is tenant-level configuration, not a provider-wide kill switch.
- Because the manual one-off test route has historically bypassed the tenant recovery toggle through its dedicated authorizer, tenant-level false values alone are insufficient evidence for a no-send cutover.


### Billing and delivery queue snapshot
- Live billing snapshot: 1 billing account, 0 billing periods, 0 billing usage charges, 0 billing measurements, 0 confirmed revenue-ledger rows and 0 confirmed order attributions.
- Billing must remain non-live/read-only until at least one real order is independently attributed and the revenue ledger + fee measurement are verified end-to-end.
- Current delivery request statuses: 2 `ACCEPTED`, 1 `DELIVERED`; no `PENDING` request was present in the snapshot. These are historical test states, not evidence of ongoing recovery throughput.


### Staging project inventory clarification
- The connected Supabase organization currently lists one active healthy project: `henvalt` (`ocyplckdojdubyrsxcxa`).
- The other listed projects (`henvalt_v23`, `henvalt-sales-factory`, `henvalt-core-vault`) are inactive. None has been verified as an approved, isolated staging environment, and none was reactivated.
- PR #7 now includes an ephemeral PostgreSQL 17 CI service to validate migration syntax and exercise trigger, ACL, operator audit and fail-closed behavior. This is useful database integration evidence, but it is not a substitute for Supabase staging validation of the full application schema and managed roles.


## Storefront consent and pixel compatibility audit — 2026-11-21

A read-only comparison of the deployed Cloudflare Worker, repository source, deployed Supabase RPC and live browse-candidate function found two additional V1 blockers.

### Event compatibility
- The live Worker `henvalt-pixel-collector` and repository `cloudflare/pixel-collector.js` allow `page_viewed`, `product_viewed`, `product_added_to_cart`, and `checkout_started`.
- The Shopify Pixel extension also emits `product_removed_from_cart`.
- The live Worker rejects that event before it reaches Supabase. The deployed legacy SQL function already recognizes the event type, so the Worker allowlist is the compatibility gap.
- Candidate fix in this branch adds `product_removed_from_cart` to the Worker allowlist.

### Server-side consent enforcement
- The Pixel extension itself returns before `fetch` when `analyticsProcessingAllowed` is not true. That is a useful client-side guard.
- The deployed Worker did not independently require `analytics_consent = true`.
- The deployed legacy `henvalt.ingest_pixel_event` RPC only nulls `customer_reference` when analytics consent is false; it still passed the client ID into anonymous/session references, retained the full payload (minus the public key), and could bind a checkout alias.
- Therefore server-side consent enforcement was incomplete for crafted, stale or future clients. The candidate fix rejects analytics-denied events in both Worker and SQL before rate-limit/event writes.
- The live browse-candidate function required analytics consent and customer email consent, but did not require the recorded Shopify privacy `marketing_allowed` flag. The candidate fix adds that independent marketing-privacy gate.
- Candidate migration: `202611210002_pixel_consent_and_marketing_gate.sql`.
- Candidate tests include analytics-denied no-write behavior, marketing-denied browse suppression, marketing-allowed candidate creation, and product-removal event acceptance in ephemeral PostgreSQL 17.

### Deployment boundary
- The live Cloudflare Worker and Supabase SQL function were inspected read-only; neither was changed.
- Candidate code exists in PR #7 only. No Cloudflare Worker upload, Supabase migration, Edge Function deployment, Shopify version release or production test event was performed.
- Browse recovery remains NO-GO until the candidate passes CI and is validated in an approved isolated Supabase staging environment.


### Browse-candidate currency type defect
- The live `get_browse_abandonment_candidates` return signature declares `currency character` (unbounded `character` defaults to `character(1)` in PostgreSQL).
- A direct read-only PostgreSQL check confirmed `'USD'::character` becomes `'U'` with length 1.
- This can truncate three-letter currency codes returned to the recovery worker. It requires a separately reviewed return-type migration (drop/recreate with `character(3)`, preserving exact grants and checking dependencies) or a versioned V2 RPC plus worker update.
- This is recorded as a release blocker; no production function was changed.

- The live Cloudflare pixel Worker bindings were checked without revealing values: `SUPABASE_URL` targets the active `henvalt` project, the publishable key is present, and `COLLECTOR_SHARED_SECRET` plus `RATE_LIMITER` bindings are present.


### n8n execution-data retention evidence
- Historical delivery execution `31260` from 2026-11-14 remained readable through the connected n8n API on 2026-11-21.
- Its execution payload included the full recipient field, subject, HTML email body, tracking URL and unsubscribe URL. Recipient details are intentionally not copied into this document.
- This proves that sensitive delivery content remained in execution history for at least seven days. It does not establish the configured maximum retention period.
- The connected n8n toolset exposes workflow and execution reads but not instance-level execution-pruning/redaction settings. Those settings remain unverified and require owner/admin evidence.
- Do not bulk-delete or alter execution history without an approved retention policy and evidence-preservation decision.


### Shopify webhook ingress binding
- Live Cloudflare Worker `henvalt-clean-ingress-v1` has the required `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET` and `N8N_INGEST_URL` bindings configured.
- The configured upstream target is `n8n.henvalt.com` at `/webhook/henvalt/ingest`.
- This matches the active `HENVALT_INGEST` workflow's POST webhook path `henvalt/ingest`.
- The Worker source validates Shopify HMAC before forwarding the raw request. This confirms the configured ingress path aligns with n8n, but does not prove that a live Shopify webhook was delivered end-to-end today.

- The active connection for `ur4jvw-nz.myshopify.com` has one active, non-revoked pixel key with a persisted Shopify Web Pixel ID. This proves a pixel identity was created for that connection, but does not prove the currently checked-out extension version is the one installed or that a live storefront event is reaching the current collector.
- The inspected execution runtime metadata also reports `redaction.production = false` and `redaction.manual = false`; this is additional evidence that no effective redaction has been demonstrated for either execution mode.


### Production webhook receipt snapshot
- `webhook_events` contains 44 `checkouts/create` events and 49 `checkouts/update` events, with the latest receipt at 2026-11-14 15:44 UTC.
- It contains 36 `carts/update` events, latest 2026-11-14 15:10 UTC; 2 customer email marketing consent updates, latest 2026-11-08 16:47 UTC; and 1 `carts/create`, latest 2026-11-08 11:11 UTC.
- No Shopify webhook receipt later than 2026-11-14 was present in the snapshot on 2026-11-21. The Cloudflare-to-n8n endpoint configuration matches, but current live event delivery is not demonstrated.


### Cloudflare ingress observability snapshot
- Live `henvalt-clean-ingress-v1` has observability enabled, head sampling rate 1, logs enabled, persistent logging enabled and invocation logs enabled.
- The inspected Worker source logs only structured failure metadata (`shop`, `topic`, `webhookId`, upstream status); no request body or customer email is passed to its console error calls.
- This still retains store-domain and webhook identifiers in Cloudflare logs. Confirm the account's log retention and access policy before release.
- The pixel collector Worker has no explicit observability settings returned by the settings API.


### Exact provider-token release boundary
- The live `get_mailersend_token_for_delivery(uuid, uuid)` function first updates the matching `delivery_requests.provider_claimed_at` from NULL to a timestamp, and only after that reads the Vault secret and returns the token.
- Its authorization predicate contains a narrowly hard-coded one-off test exception tied to a specific tenant, opportunity, test-only message marker and idempotency key. That exception bypasses the tenant `recoveryEnabled` flag for the test route.
- The candidate interlock trigger blocks the `provider_claimed_at: NULL -> timestamp` update before the function can read/return the provider token. It therefore covers the observed one-off exception as well as the ordinary send path.
- The exact one-off recipient address and secret references are intentionally omitted from repository evidence.


### Browse send-time consent recheck
- The live `browse_opportunity_advanced` helper is used by `authorize_delivery_request`, `get_mailersend_token_for_delivery` and `get_recovery_worker_context`.
- Filtering only new browse candidates is insufficient because previously created opportunities could still reach delivery authorization.
- Candidate pixel migration now makes this shared helper fail closed when the source event is missing or lacks analytics-processing and marketing permission, so existing browse opportunities are rechecked again at context/authorization/token-claim time.
- PostgreSQL acceptance tests cover marketing-denied suppression, marketing-allowed eligibility and missing-source fail-closed behavior.
