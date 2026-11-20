# Isolated n8n delivery rehearsal boundary — 20 November 2026

**Scope:** PR #6 candidate documentation only  
**Decision:** production HOLD; no staging import or workflow mutation authorized  
**Observed source:** read-only inspection of active `HENVALT_DELIVERY` workflow (workflow ID is intentionally not repeated here)

## 1. Exact-head CI checkpoint

Candidate PR head at review time: `d45f237ccf7477cf9489207cbf5a971d0c892e29`.

- Identity V2 validation run `44776229716`: completed successfully on the exact PR head.
- Shopify configuration/static validation run `44776229745`: completed successfully on the exact PR head.
- The Shopify deployment job was skipped.
- These runs validate candidate code and disposable test infrastructure only; they do not validate or change production n8n.

## 2. Delivery graph findings

The active delivery workflow has multiple independent entry points that must be assessed separately:

1. Internal delivery webhook → normal validation and delivery path.
2. Execute Workflow Trigger → internal Recovery-to-Delivery handoff.
3. Manual one-off test sender → authorization RPC → the same production delivery Edge Function.
4. Tracking-link and click-confirm handlers.
5. Unsubscribe GET and POST handlers.
6. MailerSend provider-event and inbound-reply handlers.

The manual one-off sender is not merely a preview: its graph reaches the live delivery Edge Function. Its current source also contains hard-coded personal test-recipient and delivery-request identifiers. Those values are deliberately excluded from this report and must not be copied into candidate fixtures, logs, or pull-request discussion.

Do not disable every webhook as a shortcut. Tracking, unsubscribe, provider-event, and inbound handlers are not send entry points and must remain available unless a separately reviewed requirement says otherwise.

## 3. Required candidate-only staging transformation

If an owner-controlled, separate n8n staging workspace is later identified and explicitly approved:

- Import a sanitized export as an **inactive draft** into that separate workspace only.
- Replace the manual one-off sender branch with a synthetic fixture that terminates at a local/mock transport. Do not retain its live Edge Function URL, personal recipient, real delivery ID, or provider credential reference.
- Stub or block every HTTP destination by default. The test must fail on any unapproved hostname and specifically on any MailerSend provider request.
- Keep the normal delivery and internal handoff branches present for structural tests, but route their provider boundary to a mock that records request count and returns deterministic synthetic responses.
- Keep tracking, unsubscribe, provider-event, and inbound paths separate from outbound delivery tests. Use synthetic tokens and signatures.
- Verify the staged workflow is inactive before and after import; do not publish or activate it.
- Do not create a fourth logical workflow. The only permitted responsibilities remain Ingest, Recovery, and Delivery.
- Do not use production credentials, production webhook URLs, production database IDs, live customer data, or copied execution payloads.

If no separate owner-controlled staging workspace exists, stop at offline CI fixtures. Do not import into any of the three active production workflows.

## 4. Required structural and runtime assertions

A future staging harness must assert all of the following before it can be called no-send:

| Case | Required evidence |
|---|---|
| Internal delivery webhook | Synthetic request reaches validation; mock provider calls = 0 |
| Recovery Execute Workflow handoff | Synthetic opaque handoff reaches validation; mock provider calls = 0 |
| Manual one-off sender | No live sender node or credential; branch ends at mock; mock provider calls = 0 |
| Tracking GET / click confirm | Synthetic token only; redirect target allowlisted; no delivery invocation |
| Unsubscribe GET / POST | Synthetic token only; suppression path works; no delivery invocation |
| MailerSend events / inbound | Synthetic signed raw-body fixture; no outbound send invocation |
| Unexpected destination | Harness fails immediately; test is failed, not silently skipped |
| Sensitive data | Serialized inputs, outputs, errors, and logs contain no recipient, message body, token, secret, or production identifier |

A graph inspection alone is not a runtime pass. Each entry point needs an explicit test and a captured result from the same immutable candidate revision.

## 5. Current disposition

- Exact PR-head CI: PASS.
- Live delivery workflow: still active and send-capable.
- Manual one-off branch: identified as a live sender path; privacy-safe isolation required.
- Other delivery-related webhook handlers: preserve and test independently.
- n8n retention/redaction: still unverified from account settings.
- Separate zero-cost staging n8n workspace: not established.
- Staging import: NOT STARTED.
- Production changes: NONE.

This document is a rehearsal specification, not deployment authorization. Production remains untouched until separate explicit approval names the exact production target and operation.
