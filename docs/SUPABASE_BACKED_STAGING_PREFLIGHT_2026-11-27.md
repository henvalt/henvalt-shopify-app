# Supabase-backed staging preflight — 27 November 2026

This preflight is a metadata-only gate for the Supabase-backed candidate. It deliberately does not use the legacy n8n staging identity inventory, because the candidate ingress path now terminates at a Supabase Edge Function. The three logical business stages remain INGEST, RECOVERY, and DELIVERY; this file does not assert that the recovery and delivery runtimes are implemented or deployed.

## Run

```bash
node scripts/supabase-staging-preflight.mjs
```

The script makes no network calls, deploys nothing, and never prints secret values. It requires the operator to supply the actual staging environment settings and explicit boolean confirmations.

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

## Validation status

A dedicated GitHub Actions contract test covers production-host rejection, exact staging callback and Worker host binding, mandatory no-send controls, development-store identity, and suppression of secret values in output.

**This preflight is not an end-to-end acceptance test.** A pass means only that supplied staging metadata is internally consistent. It does not prove that the credentials, Vault entries, Cloudflare secrets, Shopify store, Worker deployment, or Edge Functions actually exist.
