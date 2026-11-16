# HENVALT repository-to-production source parity audit

**Status:** read-only review of the preparation branch repository and deployed Supabase function behavior. No source or production runtime was changed in this audit.

## Confirmed repository contents

The current repository contains these Shopify-facing Edge Function source folders:
- `supabase/functions/henvalt-shopify-oauth/index.ts`
- `supabase/functions/henvalt-shopify-token-refresh/index.ts`
- `supabase/functions/henvalt-merchant-dashboard/index.ts`
- `supabase/functions/henvalt-dashboard/index.ts`

The deployed `henvalt-shopify-privacy` function was inspected in Supabase, but **there is no matching `supabase/functions/henvalt-shopify-privacy` source folder in the repository tree**. This creates a source-of-truth gap for a critical Shopify compliance endpoint. Before modifying or redeploying it, recover its exact deployed source into version control, review it, and preserve its current production version as a baseline.

## OAuth source findings

The repository's OAuth source:
- Reads one `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET` pair from environment.
- Validates callback HMAC with that one secret.
- Stores OAuth state with state hash, shop domain, expiry and initiating user ID; no app key is present.
- Exchanges the OAuth code with the same global client ID/secret.
- Calls `control_plane_finalize_shopify_oauth_install_expiring_for_owner` with state/shop/token/scopes/owner data, but no app key.
- Does obtain a `connectionId` from finalization for downstream pixel activation; this does not make the app identity itself multi-app aware.

The deployed OAuth function was independently inspected as v27 and uses the same single-global-app credential architecture. The repository source is consistent with the key identity limitation found in production.

## Token refresh source findings

The repository's refresh source:
- Reads one global `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET`.
- Claims refresh by shop domain only.
- Calls Shopify using the global app credentials.
- Completes/fails refresh by shop domain only.
- Does not resolve app identity from the stored connection.

This matches the deployed refresh function v1 audit. A public multi-app rollout requires connection-bound app identity and credential resolution before this service can refresh tokens for more than one Shopify app.

## Dashboard source findings

The repository's `henvalt-merchant-dashboard` source:
- Authenticates the Supabase user.
- Resolves tenant membership.
- Queries active Shopify connections for that tenant with a limit of 2.
- Returns HTTP 409 unless exactly one active connection exists.
- Calls `control_plane_dashboard_summary` using the one selected shop domain.

This is a safe fail-closed behavior for the current single-store dashboard but prevents a tenant with multiple active stores from using the dashboard. It should become a server-validated store selector, not an arbitrary client-provided tenant or connection ID. The summary RPC must then be connection-scoped.

## Cloudflare Worker source findings

The repository's `cloudflare/worker.js`:
- Accepts only the fixed `POST /shopify/webhooks` route.
- Reads one global `SHOPIFY_API_SECRET`.
- Validates raw-body HMAC, then forwards original request headers and raw body to the configured n8n ingest URL.
- Does not select an app identity, use a route-level app key, or set a trusted internal app identity for downstream verification.

This is a single-app legacy ingress implementation. The public-app architecture needs explicit app-key routing with an allow-list, per-app server-side secret lookup, raw-body HMAC verification before forwarding, and a trusted internal identity that cannot be chosen by an unsigned shop header. n8n/Supabase must independently validate the trusted app identity and event connection.

**Important:** the Worker source in GitHub is not proof of the exact deployed Cloudflare Worker version. Compare live Worker source and bindings before any future deployment; do not overwrite the production Worker based only on repository contents.

## Privacy endpoint source-of-truth blocker

The deployed privacy handler is a required Shopify compliance surface, but its source is absent from this repository tree. This must be corrected before any privacy-function refactor:
1. Export the exact deployed source and metadata/version.
2. Add it to `supabase/functions/henvalt-shopify-privacy/index.ts` as a source recovery commit.
3. Compare it line-by-line with deployed behavior and confirm environment secret names are not included as values.
4. Add tests for raw-body HMAC, unknown/uninstalled shops, duplicate webhook IDs, exact store scoping, customer export/redaction, shop redaction and expiry purge.
5. Only then design the app-aware replacement; do not deploy it as part of source recovery.

## README accuracy note

The repository README includes historical launch statements and explicitly lists several open launch gates. Treat it as project documentation, not as proof of current live configuration. The source and deployed function audits above take precedence for the identity architecture. README should be reconciled only after source recovery and a verified deployment inventory.

## Next source-parity tasks

- Recover deployed privacy function source.
- Compare deployed `henvalt-control-plane`, pixel proxy and dashboard variants with repository source.
- Compare production Cloudflare Worker source and route/binding configuration against `cloudflare/worker.js`.
- Map all active n8n RPC calls to committed migration/function contracts.
- Add CI checks preventing a deployed-only Edge Function from being changed without a committed source counterpart.
- Keep any future app-key implementation coherent across OAuth, refresh, webhook Worker, privacy, n8n, database and dashboard.

## Safety

No Edge Function source was deployed or modified in Supabase. No Cloudflare Worker was changed. No n8n workflow was edited. This document records repository/runtime parity findings only.
