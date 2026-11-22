# Production control-plane v24 baseline and legacy-route retirement plan

Captured 2026-11-22 from the active Supabase function `henvalt-control-plane` in project `ocyplckdojdubyrsxcxa`.

## Immutable source baseline

- Deployed version: **24**, status **ACTIVE**
- Gateway `verify_jwt`: **false**
- Deployed source SHA-256: `b3975326b8805f7883aedd797c34f8667cd2289ffc56a84765517b373eb90fdf`
- Exact source snapshot: `supabase/audit-baselines/henvalt-control-plane-v24.ts`
- Machine-readable metadata: `supabase/audit-baselines/henvalt-control-plane-v24.json`

The function itself requires a Bearer token and verifies it by calling service-only `control_plane_verify_api_token`, which reads Vault secret `HENVALT_CONTROL_PLANE_TOKEN`. It also requires `x-henvalt-shop`. Gateway JWT verification being disabled is therefore not the same as an unauthenticated handler, but it makes the handler's custom token boundary security-critical.

## Routes that must be retired or replaced

| Route | Current downstream dependency | Finding |
|---|---|---|
| `POST /v1/billing/usage/claim` | `control_plane_claim_billing_usage` | Legacy claim path lacks candidate tenant/shop/subscription locking and deterministic reconciliation protections |
| `POST /v1/billing/usage/result` | `control_plane_record_billing_usage_result` | Legacy result path can downgrade SUBMITTED after a late failure |
| `POST /v1/webhooks/shopify` | Forwards raw Shopify body and selected original headers to n8n | Must be included in caller and ingress-path inventory before route replacement |

The legacy billing RPCs are service-role-only at the database ACL boundary, and the three active n8n workflows inspected on 2026-11-22 did not call these HTTP routes. That does **not** prove no app, dashboard, worker, external integration, or old deployment calls them.

## Safe retirement sequence

1. Search the repository, Shopify app source, dashboard, Cloudflare Worker, n8n workflows, deployment configuration, and available runtime logs for both route paths and the legacy RPC names.
2. Identify all deployed consumers and their exact deployed versions. Do not infer absence from repository search alone.
3. Version-control and review the complete replacement control-plane source before changing the live function. Do not overwrite v24 with a partial handler.
4. Route every billing usage claim/result through the candidate idempotent worker and reconciliation contract; prove duplicate, timeout, late-success, late-failure, deterministic rejection, refund/credit, and subscription-lock behavior in isolated staging.
5. Preserve the webhook proxy only if it remains an intentional supported ingress. Otherwise migrate its callers to the verified atomic ingress endpoint and prove the exact acknowledgement contract.
6. Remove legacy routes and RPC grants only after the caller inventory is complete and staging acceptance passes.
7. Deploy the complete replacement as a reviewed versioned change; verify route behavior and error budgets immediately after deployment.

## Release gate

**NO-GO for legacy billing-route retirement and production billing cutover** until the external caller inventory is complete. Do not rotate the global control-plane token as a substitute: rotation can break unknown callers without removing the vulnerable legacy semantics.

This is an audit baseline and release plan only. It does not alter the active function, Vault, production database, n8n, Shopify configuration, or billing state.
