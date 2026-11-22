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
