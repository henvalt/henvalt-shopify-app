# Integrated staging acceptance runbook

Status: candidate runbook only. Nothing in this document authorizes a deployment, migration, secret change, OAuth install, scheduler, or provider-send enablement.

## Non-negotiable environment boundary

- Staging Supabase project ref: `xidhtmrfvsgfmyltjuja`.
- Staging URL: `https://xidhtmrfvsgfmyltjuja.supabase.co`.
- Production project ref: `ocyplckdojdubyrsxcxa`. Never use it for this runbook.
- Shopify development store: `hen-tst-1.myshopify.com`.
- Keep `henvalt.provider_send_control` global `provider_sending_enabled=false` throughout discovery, OAuth, webhook, recovery-generation, and no-send acceptance.
- No cron/scheduler is created during manual acceptance.
- Do not configure production secrets, use production database credentials, or deploy any function to production.
- A successful CI run is not evidence of a live Shopify install, signed webhook, real AI response, provider delivery, attribution, or billing result.

## Dependency and source review

The candidate work is split across the open PR chain:

1. PR #7: database lifecycle, send interlock, retry/reconciliation, and billing-safety migrations. Review its full migration dependency set against the current staging schema before applying anything.
2. PR #22: recovery candidate scanner.
3. PR #23: Groq generation gateway.
4. PR #24: recovery intervention executor.
5. PR #25: public tracking and unsubscribe actions.
6. PR #26: delivery dispatcher and explicit response-stage contract for the protected MailerSend worker.

PRs #22–#26 are stacked. Merge/rebase them only in dependency order after reviewing the complete diff and CI. This runbook does not merge them. Confirm the exact migration filenames and ordering from the reviewed PR #7 diff; do not infer ordering from this document or run a blanket production migration command.

## Staging function inventory and authentication

Deploy only after the corresponding reviewed code is present in the staging deployment source.

| Function | Authentication | Special configuration |
|---|---|---|
| `henvalt-recovery-scan` | JWT verification ON; service-role bearer required by handler | Staging Supabase URL |
| `henvalt-groq-generate` | JWT verification ON; service-role bearer required by handler | `GROQ_API_KEY` |
| `henvalt-recovery-executor` | JWT verification ON; service-role bearer required by handler | `HENVALT_PUBLIC_ACTIONS_BASE_URL` must point to deployed staging public-actions function |
| `henvalt-public-mail-actions` | JWT verification OFF only; public token validation is performed by database RPCs | Staging Supabase URL; no browser-supplied service-role credential |
| `henvalt-delivery-dispatcher` | JWT verification ON; service-role bearer required by handler | Staging Supabase URL |
| `henvalt-mailersend-delivery` | JWT verification ON; service-role bearer required by handler | Existing protected provider worker; it must remain protected |

Do not disable JWT verification on any function except the public token-based `henvalt-public-mail-actions` endpoint. Do not expose the service-role key to the browser, Shopify app frontend, logs, or repository.

Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. The additional secret needed for a live generation test is `GROQ_API_KEY`. Set `HENVALT_PUBLIC_ACTIONS_BASE_URL` only after the public actions function is deployed and its staging routes pass manual tests:

`https://xidhtmrfvsgfmyltjuja.supabase.co/functions/v1/henvalt-public-mail-actions`

Never put a placeholder URL in this setting.

## Manual acceptance sequence

### Gate 0 — staging preflight

- Confirm the Supabase dashboard project ref is exactly `xidhtmrfvsgfmyltjuja`.
- Confirm the global provider-send control exists and is false.
- Confirm no recovery or delivery cron exists.
- Confirm the staging functions and migrations are from the reviewed PR heads.
- Confirm no production project is selected in any CLI, dashboard, or deployment command.
- Stop if any check is uncertain.

### Gate 1 — database prerequisites

- Apply only the reviewed PR #7 migration set to the isolated staging project, in the exact dependency order established by the PR's migration files.
- Confirm each migration succeeds; stop at the first failure.
- Verify the candidate scanner RPCs exist and are executable by service_role only.
- Verify job claiming, intervention claiming, idempotency, delivery lifecycle, provider egress fence, and billing locks using the PR's PostgreSQL acceptance tests.
- Verify the global provider-send control remains false after migrations.
- Do not apply this migration set to production.

### Gate 2 — deploy no-send building blocks

- Deploy `henvalt-public-mail-actions` first with JWT verification OFF.
- Manually test an invalid tracking token and invalid unsubscribe token; both must fail generically without exposing customer data.
- Confirm GET unsubscribe only displays confirmation and does not unsubscribe; only explicit POST confirmation performs suppression.
- Deploy `henvalt-groq-generate`, `henvalt-recovery-scan`, `henvalt-recovery-executor`, and `henvalt-delivery-dispatcher` with JWT verification ON.
- Keep the existing `henvalt-mailersend-delivery` function protected with JWT verification ON.
- Set the executor public-actions base URL to the exact staging endpoint above only after Gate 2 public-route tests pass.
- Do not create a scheduler.

### Gate 3 — Shopify identity and signed events

- In Shopify Dev Dashboard, verify the HENVALT staging app URL and exact staging OAuth callback before installation.
- Install only on `hen-tst-1.myshopify.com`.
- Confirm the OAuth callback creates/updates exactly one staging tenant connection and securely stores the token; never print or copy the token into chat, logs, or the browser.
- Send a real Shopify test webhook and verify raw-body HMAC validation, shop-domain binding, webhook ID idempotency, and event persistence in staging.
- Confirm no production endpoint is called.
- Stop if the Shopify app ownership, callback, or store identity is ambiguous.

### Gate 4 — recovery creation with provider disabled

- Invoke the candidate scanner manually twice.
- Confirm checkout/cart/browse candidate processing is idempotent and does not create duplicate opportunities/interventions/jobs.
- Confirm the executor claims at most one eligible job per invocation.
- Confirm tenant state, consent, suppression, sender identity, inactivity window, and eligibility are rechecked at execution time.
- Confirm the generation gateway validates structured output and rejects model-supplied URLs.
- Confirm the executor creates one valid message and one pending delivery request with tracking/unsubscribe tokens that point to the deployed staging public-actions endpoint.
- Confirm no provider request occurs and the global send interlock remains false.

### Gate 5 — delivery pause proof

- Invoke the dispatcher with the staging service-role token while global sending remains false.
- Expected result: `PAUSED` with `provider_sending_disabled`.
- Confirm it reads the `henvalt` schema and does not query/select a delivery request, call `henvalt-mailersend-delivery`, or contact MailerSend.
- Confirm delivery attempts remain unchanged.
- Stop if the dispatcher does anything other than pause before queue selection.

### Gate 6 — attribution and billing evidence

- Use a controlled staging test order and a documented test correlation ID.
- Verify the Shopify order webhook is signed, deduplicated, tenant-bound, and attributed to the correct intervention only under the database attribution rules.
- Verify revenue ledger and billing measurements remain append-only/consistent and that no charge is submitted.
- Verify duplicate order webhooks do not duplicate recovered revenue or billing measurements.
- Do not infer a recovery from a click or provider acceptance; require the order attribution rules to confirm it.

## Separate approval required before any real email

The no-send gates above do not prove actual MailerSend delivery. A later, separately approved test must specify a controlled recipient, message content, tenant, sender identity, and an explicit one-message send authorization. Only after that approval may the staging interlock be enabled for the bounded test. Re-disable it immediately afterward and verify the provider attempt, webhook events, unsubscribe behavior, and reconciliation evidence. Never use a real customer list for this test.

## Launch blockers that this runbook does not waive

- Real Shopify development-store OAuth and signed webhook round-trip have not yet been proven.
- Real Groq generation has not yet been proven; it needs a staging-only API key.
- Real provider delivery is intentionally untested while the global interlock is false.
- Recovery and delivery schedulers do not yet exist and must not be added before manual acceptance.
- Public Shopify App Store compliance, embedded App Bridge/session-token behavior, protected-data approval, and merchant billing approval remain separate launch work.
- Production no-send interlock and production migration readiness require their own read-only verification and explicit change approval.
