# Owner-controlled automation recovery plan — 2026-11-20

## Decision

The existing n8n Cloud account is not under the HENVALT operator's control. Treat it as an unavailable third-party dependency. Do not request access to it, inspect it further, change it, execute workflows in it, export from it, or rely on its retention, credentials, execution history, or workflow state.

This is an ownership boundary, not a technical configuration task. The account owner must resolve access independently; HENVALT's recovery plan does not depend on that happening.

## Safety status

- Production remains HOLD.
- No production workflow was modified, executed, activated, deactivated, or unpublished by this plan.
- No production Supabase function, database, secret, provider credential, Shopify app, Cloudflare Worker, or MailerSend setting was changed.
- No outbound email was sent.
- The existing production Supabase V1 MailerSend Edge Function remains send-capable until an authorized, independently verified stop is implemented.
- Retention and redaction on the inaccessible n8n account are NOT VERIFIED. Do not infer settings from n8n defaults, plan documentation, or the connector's partial workflow metadata.

## Replacement principle

Create a new automation runtime only in an account/workspace controlled by the HENVALT owner. Do not attempt to recover or clone the former partner's workspace. Do not copy production secrets, customer payloads, access tokens, webhook URLs, or execution data into the replacement.

The replacement is not considered available merely because a workflow export or repository specification exists. It becomes an eligible isolated staging environment only after the owner can sign in, control billing/plan and instance settings, manage credentials, and demonstrate that the runtime is isolated from production.

## Minimum replacement shape

Preserve the deliberately small three-workflow design:

1. `HENVALT_INGEST` — accept authenticated, schema-validated synthetic or approved tenant events; enforce idempotency; write canonical event/queue state; never send.
2. `HENVALT_RECOVERY` — claim eligible work with bounded leases; evaluate consent, suppression, tenant status, quiet hours, expiry, and cost reservation; create delivery intents; never contact an email provider.
3. `HENVALT_DELIVERY` — accept only authorized delivery intents; apply the sender interlock before any provider credential lookup or network operation; record outcomes idempotently. In staging, provider egress must be blocked and the provider node must be replaced with a deterministic mock.

Do not add a fourth workflow to compensate for missing account access. Tracking, unsubscribe, provider-event, and inbound handlers should remain separately classified and must not be accidentally disabled by a sender-only stop.

## Owner-controlled workspace prerequisites

Before any staging import or deployment:

- Confirm the owner can sign in and administer the workspace.
- Confirm the workspace is isolated and has no production credentials, production webhook URLs, or production customer data.
- Confirm instance-level execution-save, pruning/retention, and redaction settings from the actual owner-visible console; record redacted evidence and the effective plan/entitlement.
- Confirm provider egress is blocked at the network/runtime boundary, not merely by a workflow convention.
- Use synthetic tenants, synthetic IDs, and reserved `.invalid` recipient addresses.
- Store credentials only in the owner-controlled secret manager after the isolated environment is approved; never place credentials in Git.
- Record workspace identity, environment identifier, candidate commit SHA, and test evidence.

If a no-cost owner-controlled runtime cannot meet these prerequisites on the existing hosting plan, keep staging blocked. Do not purchase hosting or upgrade a plan without a separate decision.

## Migration and acceptance sequence

1. Recover or reconstruct workflow definitions from HENVALT-owned repository specifications and tests only; do not depend on exports from the inaccessible account.
2. Review each node and connection against the three-workflow contract; identify every trigger, HTTP request, execute-workflow handoff, credential reference, and retry path.
3. Import into an isolated owner-controlled workspace with provider nodes mocked and network egress blocked.
4. Verify every sender entry point, including the ordinary delivery ingress and manual one-off test branch, fails closed. Verify recovery-to-delivery handoff also fails closed.
5. Verify tracking, unsubscribe, inbound, and provider-event handlers do not invoke a sender.
6. Capture execution retention/redaction evidence using synthetic executions and inspect whether recipients, bodies, tokens, authorization headers, and raw webhook payloads persist.
7. Run the full acceptance matrix against the exact deployed candidate SHA. Any unverified retention/redaction behavior or provider egress path blocks sign-off.
8. Only after isolated staging acceptance, prepare a separate production change proposal. Production remains untouched until explicit approval names the exact target, change, and window.

## Current gate

| Gate | Status |
|---|---|
| Former n8n account ownership/control | Unavailable to HENVALT operator |
| Former account retention/redaction | NOT VERIFIED; do not access or rely on it |
| HENVALT-owned replacement workspace | Not established |
| Three-workflow replacement specification | Defined in this document |
| Isolated staging import and runtime proof | NOT STARTED |
| Sender interlock in live production | NOT DEPLOYED |
| Production approval | NOT GRANTED |

## Explicit non-goals

This plan does not authorize account recovery against another person's account, password resets, credential rotation in an inaccessible workspace, workflow export from that workspace, production cutover, production disablement, or any live email test.
