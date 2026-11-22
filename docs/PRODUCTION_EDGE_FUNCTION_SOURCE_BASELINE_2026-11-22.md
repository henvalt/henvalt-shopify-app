# Production Edge Function source baseline — 2026-11-22

Captured the exact `index.ts` source returned by Supabase for five active production Edge Functions. These snapshots preserve what is actually deployed, not what the repository currently proposes.

| Function | Deployed version | Gateway JWT | Source lines |
|---|---:|---:|---:|
| `henvalt-shopify-privacy` | 1 | disabled (handler verifies Shopify HMAC) | 198 |
| `henvalt-privacy-export` | 1 | disabled (handler verifies Supabase Auth and owner/admin membership) | 115 |
| `henvalt-merchant-dashboard` | 4 | disabled (handler verifies Supabase Auth and tenant membership) | 142 |
| `henvalt-shopify-oauth` | 27 | disabled (OAuth state/HMAC and route-specific checks) | 387 |
| `henvalt-mailersend-delivery` | 1 | enabled | 174 |

## Exact snapshots

All five source files are under `supabase/audit-baselines/deployed-2026-11-22/`. The manifest records each function ID, deployed version, gateway JWT setting, Supabase deployment-artifact checksum, source size, and Git blob SHA. CI recomputes the Git blob SHA from each stored source file, so accidental edits to a baseline are detected.

## Why this matters

A comparison against the candidate branch showed the current repo files are not all byte-identical to the live deployments:
- The merchant dashboard v4 source differs from the candidate `supabase/functions/henvalt-merchant-dashboard/index.ts`.
- The Shopify OAuth v27 source differs from the candidate `supabase/functions/henvalt-shopify-oauth/index.ts`.
- The active MailerSend delivery v1 entrypoint differs substantially from the current repo entrypoint/handler split.
- The privacy and privacy-export audit baselines already existed with explanatory header comments; these new snapshots preserve the exact deployed entrypoint without those annotations.

This is not automatically evidence that the live functions are broken. It means a replacement must be reviewed against the exact deployed source and runtime behavior, rather than blindly deploying a repository file that may omit live behavior.

## Secret handling and scope

The captured sources were checked for common literal secret/token/private-key patterns before storage. No such values were found. Runtime environment values, Vault contents, customer data, and request logs are not included.

This is a read-only audit capture. No Edge Function was deployed, no environment variable was changed, and no production data or configuration was modified.

## Candidate-versus-production contract differences requiring staging review

- The live `henvalt-merchant-dashboard` v4 returns `ledger`, `revenueComparison`, and caller-selected `day|week|month` granularity in addition to the summary and revenue series. The current candidate source returns the summary and daily series but omits those additional fields. The current first-party dashboard HTML does not reference `ledger` or `revenueComparison`, but external consumers have not been inventoried. Preserve the existing response contract or explicitly approve and test the contract change before replacing v4.
- The live `henvalt-shopify-oauth` v27 hard-codes the prior Worker origins and redirects to the Lovable dashboard. The candidate intentionally switches to `SHOPIFY_WEBHOOK_INGRESS_BASE_URL`, `SHOPIFY_PIXEL_COLLECTOR_URL`, and the Pages dashboard URL. This is a desired infrastructure migration, but it will fail closed with `oauth_configuration_missing` unless both Worker URL variables resolve to valid HTTPS URLs. Do not deploy until the exact new Worker origins are deployed, verified, and supplied to the staging function environment.
- The candidate OAuth config requires the webhook ingress base URL to be an HTTPS origin with no path/query/fragment and the pixel collector URL to be an HTTPS URL whose path is exactly `/v1/events`. The candidate app completion URL defaults to `https://henvalt-dashboard.pages.dev`; verify it against the Shopify Dev Dashboard application URL and staging/production domain plan.
- The live MailerSend delivery v1 source is a bundled 174-line entrypoint; the repository now separates the handler module from a short entrypoint. Compare the built deployment artifact and provider-egress contract, not line count alone.

These differences are compatibility/deployment gates, not proof that either the live or candidate implementation is correct. No production function was changed.
