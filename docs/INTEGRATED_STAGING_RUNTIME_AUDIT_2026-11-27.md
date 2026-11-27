# HENVALT integrated staging runtime audit — 27 November 2026

**Status: NO-GO for end-to-end Shopify acceptance. Read-only audit only.**
**Target:** `henvalt-integrated-staging` (`xidhtmrfvsgfmyltjuja`).
**Candidate code branch:** `feat/shopify-connection-scoped-ingress`.
**Safety:** No production resources changed. No staging schema, function, Worker, secret, route, or schedule was changed by this audit. No provider request, email, Shopify mutation, or billing charge was made.

## Verified staging state

- Supabase project status: `ACTIVE_HEALTHY`, PostgreSQL 17.
- Applied migration history includes the connection-scope lineage, parent-link validation, immutable connection identity, OAuth owner-claim serialization, and identity-metadata guards through the 26 November candidate migrations.
- Only one Edge Function is deployed in this staging project: `henvalt-merchant-dashboard` (active, version 1). `henvalt-shopify-oauth` is not deployed.
- The provider-send interlock row is present and `provider_sending_enabled = false`.
- One Shopify connection fixture exists. It has no Shopify numeric shop ID, no granted scopes, and no access- or refresh-token secret references. It is not a usable OAuth connection.
- Auth user count is zero; canonical event count is zero; delivery request count is zero.
- One billing-measurement fixture exists. This is not evidence of a live Shopify billing account or a successful provider charge.
- The only active `pg_cron` jobs are privacy-request cleanup/queue jobs. No ingest, recovery, delivery, or billing worker schedule is configured.
- `pg_cron` is installed; `pg_net` is not installed.

## Verified Cloudflare staging Worker state

Two scripts exist and have a 100% deployment version uploaded:

- `henvalt-shopify-ingress-staging-no-send`
- `henvalt-pixel-collector-staging-no-send`

However, neither is a usable staging endpoint yet:

- Workers.dev subdomains are disabled for both scripts.
- Neither script has any secret bindings.
- Neither script has a Cron Trigger.
- The ingress Worker's `N8N_INGEST_URL` and host allowlist still point to `staging-n8n.invalid`; the Worker deliberately rejects that hostname.
- The pixel collector has only the no-send flag and staging Supabase URL as plain-text bindings; its required publishable-key and shared-secret bindings are absent.
- No custom route is configured.

These are intentionally inert staging uploads, not running application services.

## Runtime conclusion

The existing Supabase staging database is suitable for continued isolated work, but it is not yet integrated with Shopify. The old partner-owned n8n workspace is not an available runtime dependency. The current staging Workers do not provide a substitute yet.

A no-purchase hosting direction remains feasible in principle:

1. Keep Hostinger for the public website only.
2. Keep Supabase as the tenant database, Auth, RLS/RPC and Edge Function layer.
3. Use Cloudflare Workers for Shopify webhook ingress and, if the n8n dependency is retired, scheduled execution.
4. Preserve the three logical execution stages — INGEST, RECOVERY and DELIVERY — rather than adding a fourth workflow.
5. Keep MailerSend egress and Shopify usage billing independently disabled until their separate acceptance gates pass.

This is an architecture candidate, not an implemented migration. Cloudflare Cron-to-Supabase orchestration and the recovery/delivery worker handlers still need code, tests, deployment configuration, and isolated acceptance. Do not claim that replacing n8n is complete.

## Immediate engineering gates

1. Obtain a valid Shopify development app/client configuration and a disposable Shopify development store owned by the project owner.
2. Provision staging-only Supabase OAuth configuration and deploy the candidate OAuth Edge Function to staging; never copy production secrets.
3. Make the ingress endpoint acknowledge only after the signed webhook and replay job are durably persisted.
4. Decide whether to restore n8n under owner control or port the three execution stages to owner-controlled Workers/Edge Functions. Do not depend on the inaccessible partner workspace.
5. If porting, implement and test the three stage handlers against existing lease-fenced database RPCs. Keep all external provider egress blocked.
6. Configure staging Worker secrets and a staging-only hostname; verify health/configuration endpoints before registering Shopify webhooks.
7. Run a synthetic Shopify checkout through durable ingest, recovery eligibility, intervention, delivery generation, retry/race handling, and dashboard attribution with a network-denied provider stub.
8. Only after the no-send path passes, separately review consent, sender identity, deliverability, merchant email cost caps, uninstall cancellation, billing and Shopify privacy compliance.

## Security advisor notes

The staging security advisor reports 19 RLS-enabled tables in the private `henvalt` schema without table policies. These include billing, provider-control, delivery retry and OAuth-state tables. This is not automatically a public exposure: the schema is private and table ACLs/RPC grants matter. Do not apply blanket policies. Verify schema exposure, role grants, and service-role-only access for each table before changing anything.

The performance advisor reports many unused indexes. The staging dataset is nearly empty, so these findings are not sufficient evidence to drop indexes. Revisit after representative workload measurements.

## Release decision

**NO-GO.** The next valid milestone is a signed Shopify development-store install and one durable synthetic checkout lifecycle in isolated staging. No customer traffic, email delivery, billing, public app release, or production cutover is authorized by this audit.
