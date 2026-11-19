# HENVALT deployment and release runbook

**Status: HOLD — preparation branch only.** This runbook is an ordered release
procedure, not authorization to execute it.

## 1. Release ownership

Before any production operation, the HENVALT owner must confirm control of:

- the Shopify Partner organization and public app;
- the production Supabase project and its backup/restore process;
- the Cloudflare account, Pages project and Worker secret bindings;
- the three active n8n workflows and their credential store;
- the MailerSend account, sender domain and API token;
- the GitHub repository and deployment secrets.

Do not use a former partner's Shopify app credentials or account-owned
infrastructure as a production dependency.

## 2. Pre-deployment evidence gate

All items below must be attached to the release record before deployment:

1. Owner-controlled Shopify app ID, callback URLs, application URL, requested
   scopes, protected customer data approval and generated Pixel UID.
2. Production database migration inventory, exact V1/V2 table and FK lineage,
   unresolved historical row counts, backup verification and a tested
   forward-recovery/rollback plan.
3. A production-like clone run of the complete candidate migration chain,
   including data-volume and lock-duration observations.
4. A reviewed server-side message renderer and template contract. No raw
   customer email, provider token or arbitrary HTML may flow through n8n.
5. A signed MailerSend webhook endpoint and verified sender, Vault references,
   positive provider unit cost, merchant-funded caps and approved performance
   percentage/billing principal.
6. Reviewed import/export diffs for the three existing n8n workflows. Each
   workflow must retain its current responsibility and no duplicate V1/V2
   send path may be enabled.
7. Test cases for install, reauthorization, token rotation, uninstall,
   consent withdrawal, unsubscribe, complaint, bounce, same-store order,
   partial/full refund, ambiguous provider response, duplicate webhook and
   two stores with colliding customer/session/checkout references.
8. Exact-store privacy export/redaction and retention decisions, plus a
   monitored incident and rollback plan.

## 3. Candidate validation

Run from the repository root with Node.js 22 and Deno 2:

```bash
npm test
npm run check
```

The GitHub Actions identity workflow additionally applies migrations 001–046
to a disposable PostgreSQL 17 database and runs the SQL integration and
concurrency tests. A passing run is necessary but does not prove production
parity.

## 4. Controlled deployment order

After written owner approval for each stage:

1. **Freeze and snapshot:** pause any legacy recovery activity that could
   conflict with the migration; capture a restorable database backup and
   current Worker/workflow exports.
2. **Database:** apply the reviewed migration plan to a staging clone first.
   Compare every object and row-count result to the expected manifest. Stop
   if any lineage or lock assertion differs. Production migration requires a
   separate explicit approval.
3. **Secrets and Edge Functions:** configure server-only Supabase secrets and
   Vault entries. Deploy only the reviewed functions after the schema they
   depend on is present. Verify health, authorization failures and logs before
   routing any traffic.
4. **Cloudflare Worker:** compare the live Worker with reviewed source, verify
   route tokens and secret bindings, deploy to a test route, and prove raw-body
   signature verification. Do not replace the legacy route until duplicate
   ingress is impossible.
5. **n8n:** preserve exactly `HENVALT_INGEST`, `HENVALT_RECOVERY` and
   `HENVALT_DELIVERY`. Import reviewed workflow changes as inactive drafts,
   verify every RPC/Edge Function payload and credential reference, then
   activate one controlled store behind a feature gate. Do not enable legacy
   and V2 delivery for the same opportunity.
6. **Provider:** verify sender/domain, unit cost, cap and signed webhook event
   correlation. Route MailerSend signed events to the V2 webhook and disable
   the duplicate legacy n8n event path. Only after end-to-end verification may
   the owner set `HENVALT_V2_MAILERSEND_EVENTS_READY=true`. Begin with a
   controlled test recipient only after explicit authorization. Never retry
   an AMBIGUOUS submission blindly.
7. **Shopify:** run the manually gated unreleased-version preparation workflow,
   verify the Shopify-generated Pixel UID and app scopes, test install and
   webhooks on the owner-controlled test shop, then use the separate
   manually gated release workflow only after Shopify review.
8. **Pages:** verify the candidate dashboard against exact-store read-model
   data on preview. Merge to `main` only after approval because the production
   Pages project follows `main`.
9. **Revenue:** confirm a paid Shopify order, exact-store attribution, refunds
   and one idempotent non-charging fee measurement. Enable collection only
   after billing terms and legal review are approved.

## 5. Rollback and stop conditions

Immediately stop new V2 promotion and provider submission if any of these
occur:

- app/store/tenant identity cannot be resolved exactly;
- consent, jurisdiction, sender, provider or merchant cap evidence is stale
  or missing;
- duplicate webhook delivery changes its body digest;
- a send permit is replayed, expired or bound to another store;
- a provider submission is AMBIGUOUS;
- attribution or refund reconciliation is not idempotent;
- dashboard metrics cannot be reconciled to exact-store source rows;
- privacy export/redaction scope cannot be proven exact-store.

Rollback must stop new work before changing routing. Preserve provider-event,
cost and financial audit records. Do not blindly replay sends, release
ambiguous reservations or reactivate unsafe tenant-scoped cart/browse paths.

## 6. Current deployment state

- Candidate migrations 001–046: CI fixture only; not production-applied.
- Candidate V2 Edge Functions: branch only; not production-deployed.
- Candidate Worker changes: not deployed.
- Active n8n workflows: three legacy workflows, unchanged.
- Shopify app: checked-in TOML still contains legacy settings; no app release.
- Dashboard: branch preview only; no Pages production deployment.
- MailerSend: no V2 customer send or billing activation.

The current decision is **HOLD / NOT LAUNCH-READY**. This runbook does not
grant deployment authority.
