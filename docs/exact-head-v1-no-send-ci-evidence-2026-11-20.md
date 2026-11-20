# Exact-head V1 no-send candidate CI evidence — 2026-11-20

## Scope and safety boundary

This is repository-candidate evidence only. It does not prove that the production Supabase Edge Function or former n8n Cloud workflows are blocked. No production resource was changed or executed, and no email was sent. The former partner-controlled n8n account remains unavailable; its retention and redaction settings are unverified.

## Tested source revision

- Repository: `henvalt/henvalt-shopify-app`
- Branch: `prep/public-app-hardening-2026-11-15`
- Exact tested source SHA: `09b8b8315630fa30bb0914b5b6424766aa059e91`
- Runtime test: `tests/edge-legacy-mailersend-no-send-runtime.test.ts`
- Candidate handler: `supabase/functions/henvalt-mailersend-delivery/index.ts`

## Runtime assertions

The Deno runtime test replaces global fetch with a counter that throws on any attempted outbound request, then verifies:

- Unauthorized requests fail with 401 before parsing.
- Unsupported methods fail with 405.
- OPTIONS preflight returns 204 and advertises only POST and OPTIONS.
- Missing readiness flag and explicit false return 503 `delivery_send_disabled`.
- Only the exact lowercase string `true` passes the readiness gate; empty, uppercase, numeric, and whitespace-padded lookalikes remain disabled.
- Malformed JSON while disabled returns 503 before parsing.
- With the exact flag enabled, malformed input still fails validation with 400.
- Outbound fetch call count remains zero throughout the test.

The handler places the readiness check after service-role authentication and before body parsing, Vault credential lookup, and MailerSend fetch.

## Exact-SHA CI results

All three runs below report the exact tested SHA above and completed successfully:

| Workflow run | Workflow | Result |
|---|---|---|
| [44784425790](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44784425790) | Shopify app configuration checks and deployment | Success |
| [44784425823](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44784425823) | HENVALT exact-store identity V2 validation | Success |
| [44784416866](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44784416866) | HENVALT exact-store identity V2 validation | Success |

Job-level inspection confirmed:
- `static-validation`: success.
- `shopify-database-migration-validation`: success.
- `identity-v2-validation`: success in both identity runs.
- `deploy-shopify-version`: skipped, as intended.

## What this evidence does not establish

- It does not prove a production sender stop or production interlock deployment.
- It does not verify any live n8n sender entry point.
- It does not establish retention or redaction settings in the unavailable n8n account.
- It does not constitute isolated staging acceptance or production approval.
- The exact tested source SHA is the CI subject. This evidence document is a subsequent documentation-only commit and is not itself covered by those exact-SHA runs.

## Next gate

Continue candidate-only review and establish an owner-controlled, no-cost isolated runtime before any staging rehearsal. Keep production on HOLD until a separate, explicit approval names the exact target and change.
