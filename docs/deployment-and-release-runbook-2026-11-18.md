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

Shopify's Dev Dashboard app list is organization-scoped. The App developer role
can develop/manage apps in that organization; Organization administrators
have broader organization access. If access to the former partner's organization
cannot be restored, do not assume the existing app can be transferred. Create
a replacement app under an owner-controlled Shopify organization and treat it
as a new identity: new client ID/secret, new Vault binding, new callback and
webhook registration, and merchant reauthorization. Existing installs are not
considered migrated merely because the replacement app uses the same name.
References: [Dev Dashboard](https://shopify.dev/docs/apps/build/dev-dashboard)
and [Dev Dashboard user permissions](https://shopify.dev/docs/apps/build/dev-dashboard/user-permissions).

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

## Owner-controlled Shopify infrastructure endpoints

The app-aware OAuth V2 function must not register webhooks or pixels against a
Worker hostname inherited from a former collaborator. Its runtime configuration
requires both values below before its health check reports configured or an
install/callback can proceed:

- `SHOPIFY_REDIRECT_URI`: exact HTTPS URL on the same Supabase project origin, with path `/functions/v1/henvalt-shopify-oauth-v2/callback` and no query, fragment or credentials. The function fails closed if the deployed secret does not match its own callback route.
- `SHOPIFY_WEBHOOK_INGRESS_BASE_URL`: HTTPS origin only (no path, query,
  fragment or credentials). OAuth appends
  `/shopify/webhooks/{per-install-route-token}`.
- `SHOPIFY_PIXEL_COLLECTOR_URL`: HTTPS URL with the exact path
  `/v1/events`, without query, fragment or credentials.

Both values must point to infrastructure controlled by the current HENVALT
owner and tested against the candidate Worker source. Do not copy a URL from an
old account or infer a production hostname. Missing or malformed values fail
closed; the callback must not silently register a legacy endpoint.

## Shopify app registry and Vault binding

The V2 OAuth function deliberately has no hard-coded app secret and migration 001 deliberately seeds no app identity. A successful deployment of the function is not sufficient: an owner-controlled app row and Vault secret reference must exist before the health endpoint reports ready.

Before enabling an owner-controlled install:

1. Confirm the Shopify Dev Dashboard app is owned by the current HENVALT owner. Verify its client ID against `client_id` in `shopify.app.toml`; do not reuse a former partner's app identity.
2. Store the app's API secret in Supabase Vault using an owner-controlled, stable secret name. Do not put the secret value in Git, migration SQL, n8n, dashboard settings, or execution logs.
3. Insert the corresponding `henvalt.shopify_app_registry` row using a stable app key, the exact Shopify client ID, and `webhook_secret_ref` set to the Vault secret name or ID—not the secret value. Set `distribution_class` to the verified app class. Keep the row pending until ownership, client ID, callback and secret binding have been checked.
4. Activate the registry row only after the owner has approved the exact app identity and all required infrastructure endpoints. The resolver only returns active rows.
5. Configure the Edge Function's `SHOPIFY_API_KEY` to the same client ID. Configure `SHOPIFY_REDIRECT_URI`, `SHOPIFY_WEBHOOK_INGRESS_BASE_URL` and `SHOPIFY_PIXEL_COLLECTOR_URL` to the owner-controlled endpoints described above. The V2 OAuth function resolves the secret from Vault; it does not read a `SHOPIFY_API_SECRET` environment variable.
6. Call the OAuth V2 `/health` route. It now reports `configured:true` only when both runtime endpoint configuration and the active Vault-backed app identity resolve. The response exposes readiness booleans only, never the client secret. A missing/inactive registry row or unavailable Vault secret returns 503.

No app-registry seed or secret value is committed in this repository. This is an owner-controlled credential operation and must be performed only after the relevant schema is approved and applied to the intended environment.

## Test-store and payment-gateway constraint

A full checkout-to-paid-order acceptance test needs a Shopify store that can
complete a simulated payment. Shopify's Test payment gateway and Shopify
Payments test mode do not capture real payments, but Shopify states that a
test payment gateway can be tested only after the store has chosen a paid
plan. A development store cannot process real transactions. See
[Placing a test order](https://help.shopify.com/en/manual/checkout-settings/test-orders)
and [Activating a payment gateway in test mode](https://help.shopify.com/en/manual/checkout-settings/test-orders/payments-test-mode).

Do not purchase or upgrade a store as part of this preparation work. With the
current zero-purchase constraint, use an already-paid, owner-controlled store
with explicit permission and test mode if one is available. Otherwise, finish
the no-send CI and API-level tests, but keep real checkout/payment/order
attribution marked **BLOCKED — TEST STORE PAYMENT CAPABILITY NOT AVAILABLE**.
Never simulate success by directly inserting a paid order or attribution row
into production.

## 3. Candidate validation

Run from the repository root with Node.js 22 and Deno 2:

```bash
npm test
npm run check
```

The GitHub Actions identity workflow additionally applies candidate migrations 001–061
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

- Candidate migrations 001–062: CI fixture only; not production-applied. Exact PR head `9a64f6806d6137b7f6ce70a7d58e5118bba04707` passed identity V2 run [44864506289](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44864506289): Node **481/481**, focused uninstall/provider **15/15**, identity/cost/privacy **232/232**, Gitleaks, Deno checks, all 62 migrations on disposable PostgreSQL 17, the pixel event-before-attempt batch reconciliation lifecycle test, and the two-session attribution race. The same head passed Shopify static/configuration validation in [44864506274](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44864506274); the app-preparation/deployment job was skipped. This is candidate validation only.
- Candidate V2 Edge Functions: branch only; not production-deployed.
- Candidate Worker changes: not deployed.
- Active n8n workflows: three legacy workflows, unchanged.
- Shopify app configuration: candidate TOML now points OAuth and compliance callbacks at V2 routes, but the application URL is still the Lovable preview origin; embedded/legacy install settings, protected customer-data approval, app ownership and saved Dev Dashboard subscriptions remain unverified. No Shopify app version has been prepared or released.
- Dashboard: branch preview only; no Pages production deployment.
- MailerSend: no V2 customer send or billing activation.

The current decision is **HOLD / NOT LAUNCH-READY**. This runbook does not
grant deployment authority.

The OAuth V2 callback runtime secret is now validated against the exact callback route and Supabase project origin; a merely non-empty or mismatched redirect secret is not accepted. This is source-level fail-closed validation, not proof of the deployed secret value.


## Supabase Edge gateway JWT settings for Shopify callbacks

The candidate `supabase/config.toml` explicitly sets `verify_jwt = false` for `henvalt-shopify-oauth-v2`, `henvalt-shopify-privacy-v2`, and `henvalt-shopify-webhook-ingress`. These routes cannot use Supabase's gateway JWT because Shopify OAuth redirects/compliance callbacks and the Worker ingress carry their own protocol credentials. This is safe only because the handlers enforce merchant bearer validation for install initiation, OAuth state + Shopify HMAC on callback, app-specific raw-body HMAC for privacy, and the dedicated Worker bearer plus SQL-verified Shopify HMAC for ingress. A regression test now checks the configuration. Do not disable gateway JWT on other functions without a separately reviewed in-handler authentication contract.
