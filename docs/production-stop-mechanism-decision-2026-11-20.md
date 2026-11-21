# Production stop-mechanism decision record — 2026-11-20

## Decision

No production stop action is approved or performed by this record. The production sender remains potentially send-capable. The controlled no-send cutover is **not accepted** yet.

## Read-only re-verification

The connected n8n instance currently reports these workflows as active, with the published graph matching the draft:

| Workflow | Active | Nodes | Relevant trigger / role |
|---|---:|---:|---|
| HENVALT_INGEST | yes | 51 | Event intake |
| HENVALT_RECOVERY | yes | 46 | Scheduled recovery worker; also has a manual preview trigger |
| HENVALT_DELIVERY | yes | 62 | Internal delivery handoff and delivery webhooks; also has a manual one-off test sender trigger |

The Delivery graph contains two sender-related HTTP Request nodes: `MailerSend Send` and `MailerSend One-Off Test Email`. The one-off path is a real sender path, not a harmless preview. Delivery also hosts tracking, unsubscribe, provider-event, and inbound-reply handlers that must not be indiscriminately removed.

The current workflow settings returned by the read-only API include execution order, binary mode, time-saved mode, caller policy, and MCP visibility. They do **not** establish execution-data retention, pruning, or redaction configuration. Absence of those fields is not proof that redaction is disabled or enabled.

## Stop-mechanism assessment

1. **Unpublishing HENVALT_DELIVERY is not an acceptable narrow stop mechanism by itself.** It would stop the delivery workflow broadly, including webhook handling needed for tracking, unsubscribe, provider events, and inbound replies. It is therefore not selected as the production stop action.
2. **The candidate V1 Edge Function readiness interlock is the preferred narrow control for the V1 MailerSend transport**, because it is checked before payload parsing, provider-token lookup, and provider fetch in the candidate source. The production V1 Edge Function was previously inspected read-only and does not yet contain that interlock.
3. The normal and one-off sender paths must both be verified to terminate at the same protected boundary, and every other delivery entry point must be inventoried before any deployment.
4. A production stop control must be tested independently with missing/false readiness, malformed payloads, unauthorized requests, and a zero-outbound-request assertion. Production deployment requires explicit approval of the exact target and change.

## Candidate evidence

- Candidate no-send transport blocks MailerSend hosts, rejects non-HTTPS/unapproved destinations, and never performs network I/O.
- Synthetic Recovery → Delivery rehearsal confirms a blocked 503 is treated as DEFERRED and the lease is finished.
- Candidate sender-entrypoint contract covers the normal and one-off provider sender paths while classifying tracking/unsubscribe/inbound/provider-event handlers separately.
- Exact-head GitHub Actions validation for commit `a591f864ba2fed242061c3836fc98ec352011b3a` passed. Shopify deployment job was skipped.

## Outstanding acceptance gates

- Obtain explicit approval for the exact production stop mechanism and deployment target.
- Independently verify all live sender entry points and the deployed interlock.
- Obtain account-visible retention/pruning/redaction evidence; do not infer settings from workflow metadata.
- Complete the full acceptance matrix after the approved cutover.
- Establish a separate owner-controlled staging workspace before staging work.

**Boundary:** this record is documentation only. No n8n workflow was executed, edited, published, or unpublished. No Supabase production function, secret, database object, Shopify app release, or email provider setting was changed.
