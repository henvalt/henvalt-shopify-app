# HENVALT_DELIVERY live sender graph verification — 2026-11-20

Read-only inspection target: workflow `HENVALT_DELIVERY` (ID retained in operator records; not reproduced here).

## Snapshot

- Workflow active: yes.
- Draft version and active version matched at inspection: `621ae6ce-a006-4fed-a70e-acf774c360fb`.
- Node count: 62.
- Trigger count: 7.
- Inspection method: read-only workflow details and local graph traversal. No workflow execution or mutation.

## Confirmed sender paths

### Normal delivery path

`Internal Delivery Webhook` and `Execute Workflow Trigger` converge on `Validate & Normalize`, then `Precheck Valid?`, `Authorize & Context`, and `Cleared to Send?`. The allowed branch continues through `Build Reply-To Address` to the HTTP Request node `MailerSend Send` (POST). The result is classified and recorded downstream.

### Manual one-off sender path

`One-Off Test Email Trigger` → `Prepare One-Off Test Delivery` → `One-Off Test Authorized?` → allowed branch → `MailerSend One-Off Test Email` (HTTP Request, POST) → result classification and recording.

This is a real provider sender branch, not a preview-only branch. It must be covered by any approved no-send policy.

## Seven webhook triggers and scope classification

| Trigger | Method | Classification |
|---|---:|---|
| Internal Delivery Webhook | POST | Sender ingress; must be blocked from provider submission |
| Tracking Link Webhook | GET | Non-sender; preserve |
| Unsubscribe GET Webhook | GET | Non-sender; preserve |
| Unsubscribe POST Webhook | POST | Non-sender; preserve |
| MailerSend Events Webhook | POST | Non-sender; preserve |
| MailerSend Inbound Webhook | POST | Non-sender; preserve |
| Tracking Click Confirm Webhook | POST | Non-sender; preserve |

## Stop-control implication

Unpublishing the whole Delivery workflow would disable unrelated tracking, unsubscribe, provider-event, inbound-reply, and click-confirmation handlers. It is therefore not an appropriately narrow sender stop mechanism.

The candidate no-send transport tests and sender-entrypoint contract tests are repository-level protections only. This live workflow snapshot confirms the sender nodes and their graph paths still exist; it does not prove the live graph is blocked. The production Supabase V1 delivery function remains send-capable until an explicitly approved interlock deployment is independently verified.

## Safety and limits

- No live workflow node, connection, activation state, credential, or setting was changed.
- No workflow was executed.
- No message was sent by this inspection.
- Do not infer that retention or redaction is configured from workflow settings; those account-level controls remain unverified.
- Production stop action remains unapproved. Candidate-only work must not be described as a production cutover.
