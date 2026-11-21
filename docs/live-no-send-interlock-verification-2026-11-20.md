# Live no-send interlock verification — 20 November 2026

**Scope:** read-only production inspection plus candidate source review at `2099aeeb7d24f8019b22b955c5b17ee03c155aab`  
**Decision:** candidate interlock present; live V1 remains unprotected by that candidate change; production HOLD  
**No production actions performed.**

## 1. Candidate sender interlock

The candidate file `supabase/functions/henvalt-mailersend-delivery/index.ts` contains a fail-closed readiness check immediately after service-role authentication and before request-body parsing, Vault/RPC credential retrieval, or provider submission:

```ts
if (Deno.env.get("HENVALT_V1_MAILERSEND_SEND_READY") !== "true") {
  return json(503, { error: "delivery_send_disabled" });
}
```

Only the exact string `true` passes this gate. Missing, `false`, or any other value is denied.

The candidate test `tests/edge-legacy-mailersend-no-send-runtime.test.ts`:
- removes the readiness variable and asserts 503 / `delivery_send_disabled`;
- sets it to `false` and asserts the same;
- supplies malformed JSON to prove the disabled gate runs before body parsing;
- stubs global fetch and asserts zero outbound calls;
- verifies missing service-role authentication is rejected before parsing.

The GitHub Actions workflow `.github/workflows/shopify-identity-v2-validation.yml` explicitly runs this test with Deno and separately type-checks the legacy V1 Edge Function. This is test wiring evidence, not proof that the current PR head has passed CI. A fresh run against the exact reviewed SHA is still required.

## 2. Production parity gap

Read-only inspection of the deployed production function `henvalt-mailersend-delivery` (active version 1) showed:
- service-role bearer authentication;
- tenant-specific MailerSend credential retrieval through `get_mailersend_token_for_delivery`;
- direct POST to `https://api.mailersend.com/v1/email`;
- no equivalent `HENVALT_V1_MAILERSEND_SEND_READY` check in the deployed source.

Therefore the candidate interlock is not active in production. Do not infer that the candidate branch or its test protects the live service.

## 3. Active n8n route inventory

Read-only workflow metadata and full graph inspection:

| Workflow | ID | Active version | Nodes | Triggers |
|---|---|---|---:|---|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 | 1 |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 | schedule + manual preview |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 | 7 webhooks |

The Recovery workflow's manual trigger is named `HENVALT One-Off Email Preview`. Its branch generates and returns a copy preview; the node explicitly says no email is sent. It includes a hard-coded historical recipient in preview output. This is a sensitive execution-data/retention concern, but it is not evidence of a second provider-send route. The scheduled Recovery path creates delivery requests and calls the Delivery workflow.

The Delivery workflow's seven webhooks are:
1. `Internal Delivery Webhook` (POST) — delivery handoff entry point.
2. `Tracking Link Webhook` (GET).
3. `Unsubscribe GET Webhook` (GET).
4. `Unsubscribe POST Webhook` (POST).
5. `MailerSend Events Webhook` (POST).
6. `MailerSend Inbound Webhook` (POST).
7. `Tracking Click Confirm Webhook` (POST).

Do not disable tracking, unsubscribe, inbound, or provider-event handlers as a substitute for stopping delivery. Preserve unsubscribe and suppression functionality.

## 4. Retention evidence status

The workflow-level settings returned by n8n expose execution order, binary mode, time-saved mode, caller policy, and MCP availability. They do not expose effective instance retention/redaction policy in the returned settings snapshot. Therefore successful-run retention, failed-run retention, manual-execution retention, and instance-level pruning/redaction remain **unverified**.

Next evidence must come from the n8n instance's effective execution-data/pruning configuration and a controlled synthetic execution inspected across inputs, outputs, and errors. Do not execute the live preview or delivery workflow to gather this evidence.

## 5. Required next gates

1. Run the candidate V1 no-send Deno test and type check against one exact immutable SHA; attach the CI run.
2. Review the candidate interlock's operational control, secret ownership, default state, and rollback. The live environment must remain deny-by-default during cutover.
3. Independently enumerate all direct callers of the production Edge Function and verify that every path is stopped by the same provider-boundary gate.
4. Capture n8n instance-level retention/pruning settings and synthetic redaction evidence.
5. Complete NS-01–NS-15 on one exact candidate SHA; current acceptance remains partial.
6. Keep staging CI-only unless owner-controlled, separate, zero-cost targets are demonstrated.

## 6. Change boundary

This report and candidate source review do not authorize deployment. No production Edge Function, Supabase secret, database object, n8n workflow, Shopify setting, Cloudflare route, MailerSend setting, or customer delivery was changed. PR #6 remains a candidate; do not merge or deploy without separate explicit authorization naming the exact action and target.
