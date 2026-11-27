# Supabase-backed staging preflight — 27 November 2026

This preflight is a metadata-only gate for the Supabase-backed candidate. It deliberately does not use the legacy n8n staging identity inventory, because the candidate ingress path now terminates at a Supabase Edge Function. The three logical business stages remain INGEST, RECOVERY, and DELIVERY; this file does not assert that the recovery and delivery runtimes are implemented or deployed.

## Run

```bash
node scripts/supabase-staging-preflight.mjs
```

The script makes no network calls, deploys nothing, and never prints secret values. It requires the operator to supply the actual staging environment settings and explicit boolean confirmations.

## Canonical Worker deployment configuration

Use only `wrangler.staging.toml` for the staging ingress Worker. It now points to `cloudflare/staging-supabase-ingress-worker.js` and the exact staging Supabase project. The duplicate `wrangler.staging-supabase.toml` file was removed so two configs cannot accidentally target the same Worker name with different code. The older `cloudflare/staging-worker.js` n8n adapter remains only as a legacy test fixture and is no longer selected by the canonical staging Wrangler config.

## Required staging identity

- `SUPABASE_URL=https://xidhtmrfvsgfmyltjuja.supabase.co`
- `SHOPIFY_REDIRECT_URI=https://xidhtmrfvsgfmyltjuja.supabase.co/functions/v1/henvalt-shopify-oauth/callback`
- `SHOPIFY_WEBHOOK_INGRESS_BASE_URL=https://henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev`
- `SHOPIFY_PIXEL_COLLECTOR_URL=https://henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev/v1/events`
- `HENVALT_STAGE_INGRESS_HOST=henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev`
- `HENVALT_STAGE_PIXEL_COLLECTOR_HOST=henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev`
- An explicitly confirmed `HENVALT_STAGE_SHOPIFY_STORE` ending in `.myshopify.com`.
- A staging-only HTTPS `HENVALT_DASHBOARD_URL`; production domains are rejected.
- Owner-controlled `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET`.

## Required safety confirmations

Every item below must be set to the literal string `true`:

- `HENVALT_STAGE_NO_SEND`
- `HENVALT_STAGE_NETWORK_EGRESS_DENIED`
- `HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED`
- `HENVALT_STAGE_VAULT_SHOPIFY_APP_SECRET_PRESENT`
- `HENVALT_STAGE_INGRESS_SHARED_SECRET_PRESENT`

Also set `HENVALT_STAGE_PROVIDER_MODE=stub`.

The two `*_PRESENT` values are operator attestations, not remote secret-store verification. Before deployment, independently confirm the Shopify app secret exists in Supabase Vault under `henvalt_shopify_app_secret`, and that the same newly generated staging ingress shared secret is provisioned in both the Cloudflare Worker and Supabase Edge Function environments. Never place those secret values in source control or preflight logs.

## Scheduler capability check

Read-only staging inspection on 27 November found:

- `pg_cron` is installed (version 1.6.4).
- `supabase_vault` is installed (version 0.3.2).
- `pg_net` is available (version 0.20.4) but is not installed.
- No recovery or delivery Edge Function runtime is deployed.

Supabase's current scheduling guidance uses `pg_cron` plus `pg_net` to invoke Edge Functions and recommends storing the invocation credential and project URL in Vault. The staging project is not ready for that setup yet: enabling `pg_net` or creating schedules before the worker endpoints and authentication contract exist would create broken schedules, not working automation.

The safe order is: finish and test worker endpoints with a network-denied provider adapter → deploy only to isolated staging → verify authenticated no-send invocation → enable `pg_net` in staging → create exactly three logical schedules (INGEST replay, RECOVERY, DELIVERY) → inspect cron run history and queue outcomes. No schedule is created by this preflight.

## Current Cloudflare and Supabase deployment inventory

A fresh read-only account check on 27 November confirmed:

- The staging ingress Worker and staging pixel collector Worker both exist in Cloudflare.
- Both Workers have a prior uploaded version, but their `workers.dev` subdomains are disabled.
- Neither Worker has any bound secret names.
- The Supabase staging project currently has only `henvalt-merchant-dashboard` deployed; OAuth and webhook-ingress Edge Functions are absent.
- Supabase Vault does not contain the secret name `henvalt_shopify_app_secret`.

This means the existing Cloudflare Worker records are not a usable ingress runtime. Do not enable either public subdomain or register Shopify webhooks yet. First upload the candidate code using the single canonical Wrangler config, provision the staging-only shared secret in Cloudflare and Supabase, add the Shopify app secret to Vault, deploy the OAuth and ingress Edge Functions, then verify their health and authentication boundaries while no-send remains enforced.

## Validation status

A dedicated GitHub Actions contract test covers production-host rejection, exact staging callback and Worker host binding, mandatory no-send controls, development-store identity, and suppression of secret values in output.

**This preflight is not an end-to-end acceptance test.** A pass means only that supplied staging metadata is internally consistent. It does not prove that the credentials, Vault entries, Cloudflare secrets, Shopify store, Worker deployment, or Edge Functions actually exist.
\n\n## Shopify webhook response budget\n\nThe Cloudflare-to-Supabase Edge Function call is capped at 3.5 seconds, leaving 1.5 seconds of headroom within Shopify's five-second webhook response deadline for Worker parsing, routing, and response serialization. A timeout or upstream failure returns retryable HTTP 503; it must never acknowledge an event without a durable webhook and active replay job.\n