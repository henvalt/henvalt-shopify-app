# V1 no-send acceptance matrix and staging gate — 2026-11-20

## Safety boundary

This matrix is for a disposable isolated staging environment. Do not execute the active production workflows to test it. Production is HOLD: no active n8n workflow edits, Edge Function deployment, environment-variable changes, provider credential changes, or live email sends are authorized by this document.

## Preconditions for isolated acceptance

- Isolated Supabase project and isolated n8n instance/workspace.
- No production service-role key, MailerSend API token, Shopify access token, customer data, or production webhook URL copied into staging.
- Provider egress blocked at network level or intercepted by a deterministic mock; the test must not be capable of contacting MailerSend.
- Synthetic tenant, delivery-request IDs, and reserved .invalid email addresses only.
- Snapshot the deployed candidate commit and record the exact commit SHA before testing.
- Readiness flag absent by default; staging must remain no-send until the explicit test fixture sets a controlled value in an isolated test process.

## Acceptance matrix

| ID | Surface / entry point | Test | Expected result | Evidence |
|---|---|---|---|---|
| EDGE-01 | Supabase delivery Edge Function | Valid synthetic delivery payload; readiness flag absent | HTTP 503 delivery_send_disabled; zero outbound calls | Runtime test log + outbound-call counter |
| EDGE-02 | Supabase delivery Edge Function | Valid synthetic delivery payload; readiness flag exactly false | HTTP 503 delivery_send_disabled; zero outbound calls | Runtime test log + outbound-call counter |
| EDGE-03 | Supabase delivery Edge Function | Malformed JSON; readiness flag absent or false | HTTP 503 before body parsing; zero outbound calls | Runtime test log |
| EDGE-04 | Supabase delivery Edge Function | Missing/invalid service-role bearer | HTTP 401 before body parsing; zero outbound calls | Runtime test log |
| EDGE-05 | Supabase delivery Edge Function | Unsupported HTTP method | HTTP 405; zero outbound calls | Runtime test log |
| N8N-01 | Delivery public/internal webhook handoff | Synthetic webhook request through isolated workflow with provider HTTP node mocked | Sender path reaches interlock and fails closed; no provider request | Execution graph + mocked-node call counter |
| N8N-02 | Recovery Execute Workflow path | Synthetic recovery item invokes Delivery in isolated instance | Same fail-closed result; no provider request | Both execution IDs + mocked-node call counter |
| N8N-03 | Delivery manual one-off test branch | Run only in isolated instance with synthetic .invalid recipient and provider node mocked | Branch fails closed; no provider request | Execution ID + mocked-node call counter |
| N8N-04 | Tracking click / confirmation | Synthetic tracking event | Tracking handled without invoking sender | Execution trace |
| N8N-05 | Unsubscribe GET and POST | Synthetic unsubscribe request | Suppression state updated; no sender invocation | Execution trace + suppression record |
| N8N-06 | MailerSend events / inbound webhook | Synthetic provider event and inbound message | Event handlers process safely; no outbound email | Execution trace + provider-call counter |
| PRIV-01 | Execution data retention | Inspect effective instance-level success, error, and manual execution save settings; verify pruning policy and age | Documented effective settings and retention horizon; no unsupported assumptions | Redacted settings evidence |
| PRIV-02 | Sensitive execution data | Inspect synthetic executions for recipient, message body, provider token, authorization headers, and raw webhook payload persistence | No secrets persisted; PII minimized/redacted or covered by approved retention policy | Redacted execution metadata / screenshots |
| PRIV-03 | One-off test branch | Verify no hard-coded real recipient or production delivery-request identifier remains in isolated candidate | Synthetic fixture only | Source diff + isolated workflow export |
| REG-01 | Full acceptance | Re-run all rows against the exact isolated candidate deployment | All required rows pass; failures block staging sign-off | Signed run summary keyed to SHA |

## Current candidate evidence

- Candidate legacy V1 Edge Function checks HENVALT_V1_MAILERSEND_SEND_READY and returns 503 unless the value is exactly true; the check occurs after bearer authentication and before request-body parsing, Vault credential lookup, or provider fetch.
- Candidate Deno test exercises valid synthetic payloads with the flag missing and false, malformed JSON while disabled, unauthorized malformed JSON, and zero outbound fetch calls. It also verifies malformed input fails before outbound access when the interlock is explicitly true.
- Exact-head GitHub Actions run 44774699296 completed successfully for commit a37313f7b058c626daa4c2f34c310e12e8d8ea60. The run head SHA was independently checked and matched; its identity-v2-validation job passed, including the legacy V1 MailerSend fail-closed runtime test and Edge Function type-check. This verifies candidate CI only, not the live production Edge Function.
- The acceptance-matrix document was committed after that tested source SHA. The CI result is attributed to the exact source SHA above; it must not be represented as a CI run for later documentation-only commits.
- The active production Supabase delivery Edge Function remains v1 and does not contain the candidate interlock. Production therefore remains send-capable; no production interlock deployment has occurred.
- Active production n8n workflow settings expose execution order, binary mode, time-saved mode, and caller policy, but the supported n8n connector does not expose effective instance-level execution retention/pruning or redaction settings. Retention and redaction are NOT VERIFIED.
- n8n's official Cloud data-management guidance says execution-save controls are managed in the Cloud console under Instance settings / Runtime / Executions to save. Automatic Cloud retention depends on plan: Start/Starter retain up to 2,500 executions or 7 days; Pro up to 25,000 executions or 30 days; Enterprise up to 50,000 executions with unlimited time retention. The account's actual plan and effective settings have not been independently established, so no account-specific retention claim is made.
- n8n's official redaction guidance lists execution-data redaction as an Enterprise feature for Cloud and self-hosted. The account's entitlement and effective per-workflow or instance enforcement state have not been verified. Do not assume redaction is enabled.
- No active production workflow was executed and no production state was changed.

## Staging exit criteria

Staging is not approved until:
1. The candidate exact-SHA CI run is complete and successful.
2. Isolated deployment has no production credentials, production URLs, or provider egress.
3. Every N8N sender row and every EDGE row passes with zero provider calls.
4. Tracking, unsubscribe, and inbound/event paths remain functional without invoking the sender.
5. Retention/redaction evidence is captured and reviewed; unresolved retention behavior blocks sign-off.
6. The complete run summary records exact commit SHA, isolated environment identifiers, timestamps, test IDs, outcomes, and redacted evidence references.

## Production approval remains separate

A passing isolated matrix does not authorize production changes. Production deployment requires a separate explicit approval identifying the exact production target and approved change window.


## 20 November — live sender graph and latest exact-head CI update

### Live graph evidence added

The read-only inspection recorded in [live Delivery graph verification](./live-delivery-sender-graph-verification-2026-11-20.md) independently confirms two distinct send-capable paths in the active Delivery workflow:

1. Normal internal webhook / Execute Workflow ingress reaches the HTTP Request node `MailerSend Send`.
2. Manual `One-Off Test Email Trigger` reaches a separate HTTP Request node `MailerSend One-Off Test Email`.

The same inspection enumerated all seven Delivery webhooks. Only the internal delivery POST is sender ingress. Tracking-link GET, unsubscribe GET/POST, MailerSend events POST, MailerSend inbound POST, and tracking-click confirmation POST are non-sender handlers and should remain available during a narrow sender stop.

This establishes the live graph inventory, not live blocking. The two provider nodes remain present in the active graph. No live execution was run.

### Candidate contract coverage versus live runtime proof

- The repository candidate sender-entrypoint contract test covers both provider sender paths and classifies the six non-sender webhook handlers separately.
- The candidate no-send transport refuses MailerSend hosts, refuses unapproved/non-HTTPS destinations, performs no network I/O, and avoids logging request bodies, headers, query strings, recipient values, or credentials.
- The offline Recovery→Delivery rehearsal verifies a synthetic 503 `delivery_send_disabled` outcome, deferred lease handling, and zero provider requests.
- These are candidate code/test results. They do not insert an interlock into the active n8n workflow or block the live Supabase V1 Edge Function.

### Latest exact-head CI

Candidate source/documentation head inspected before this update: `05173c3c4d2d088cb87f6ee5d320154ab8e07a72`.

- Identity V2 validation run `44780556928`: completed successfully.
- Shopify app configuration run `44780556997`: completed successfully; app deployment step was skipped.
- The identity V2 run includes repository secret scanning, the complete Node regression suite, Edge Function type checks, the candidate V1 fail-closed runtime test, disposable PostgreSQL migrations 001–060, and the database/privacy/attribution/cost/recovery contract tests.
- These runs validate the exact inspected head only. The documentation update itself will create a new head and requires its own CI result before being described as validated.

### Current disposition

| Gate | Status |
|---|---|
| Candidate V1 Edge Function interlock implementation and offline runtime tests | Candidate CI passed |
| Candidate transport and sender-entrypoint contract tests | Candidate CI passed |
| Live Delivery sender graph inventory | Read-only inventory complete |
| Live production sender interlock | NOT DEPLOYED; production V1 remains send-capable |
| Live n8n sender branches blocked | NOT VERIFIED |
| Effective n8n retention and redaction | NOT VERIFIED; owner-visible Cloud console evidence required |
| Full isolated staging acceptance | NOT RUN; isolated owner-controlled environment not established |
| Production approval | NOT GRANTED |

Do not interpret a green candidate CI run as permission to deploy, enable a readiness flag, edit or unpublish a live workflow, or send a message. Production remains on HOLD.
