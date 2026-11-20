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

## 20 November — hostname normalization hardening (exact tested source)

The offline no-send transport was further hardened after review found that a single trailing DNS dot was normalized but repeated terminal dots were not. The transport now removes all terminal dots before allowlist and provider-host classification.

Regression coverage includes:
- MailerSend apex and subdomains, including uppercase hostnames.
- One or multiple terminal DNS dots.
- A JavaScript `Request` object rather than only a URL string.
- Allowlisted MailerSend names remain blocked.
- Recorded attempts contain only normalized hostname and method; no query, credential, recipient, or body values.
- Existing offline Recovery→Delivery tests continue to assert no provider egress.

Exact tested candidate source SHA: `991d360fae98e79226a96eab264bf8aa905908e4`.

Exact-head CI:
- Identity V2 validation: [run 44788746117](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44788746117) — success.
- Shopify static/configuration and disposable migration validation: [run 44788746254](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44788746254) — success; Shopify deployment skipped.

The tested source commit is `991d360fae98e79226a96eab264bf8aa905908e4`. This appendix is a subsequent documentation-only update and does not claim that a new source SHA was tested.

No live workflow, production Edge Function, Supabase resource, Shopify app, Worker, provider setting, or customer data was changed. No outbound email was sent.


## 20 November — Recovery lease acknowledgement and Delivery redirect boundary

Candidate source revision: `bdba8362ca0ff04452967bd31a42c73a171fa041`.

The Recovery orchestrator now treats a lease finish as confirmed only when the finisher returns both `finished: true` and the exact requested `outcome`. A regression test supplies a mismatched outcome and verifies the tick reports `LEASE_FINISH_UNCONFIRMED` rather than accepting the lease completion. Successful test fixtures now echo the requested outcome.

The V2 Delivery handoff adapter now sets `redirect: "error"` on its HTTPS Supabase Edge Function POST. Its regression test verifies redirect rejection is requested and a redirect response is not classified as an accepted handoff. Transport ambiguity remains deferred; raw exception details are not returned.

Exact-head CI for `bdba8362ca0ff04452967bd31a42c73a171fa041`:
- Identity V2 validation: [run 44794720773](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44794720773) — success; job-level inspection reports 58 successful steps and no failed steps.
- Shopify app configuration checks: [run 44794720768](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44794720768) — success; static validation and disposable database migration validation succeeded; deployment job was skipped.

This is repository-candidate CI evidence only. It does not establish that production workflows are stopped, that live n8n nodes enforce the candidate contract, or that staging exists. The former partner-controlled n8n account remains inaccessible and its retention/redaction settings remain unverified. No production resource was changed or executed; no email was sent.
