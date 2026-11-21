# Live sender-path inventory — 2026-11-20

## Scope and safety

Read-only inspection of the active Supabase Edge Function inventory and the published n8n workflow versions. No workflow was executed, no production setting or secret was changed, no deployment was made, and no email was sent.

This is an evidence snapshot, not a production cutover. Production remains on HOLD pending explicit approval.

## Confirmed live send paths

### 1. Normal delivery handoff

- Active workflow: `HENVALT_RECOVERY` (ID `3GEDoeCA4paXTaDF`).
- Node `Call HENVALT_DELIVERY` invokes active workflow `HENVALT_DELIVERY` (ID `CvVyybGJZSnklxiZ`) through n8n's Execute Workflow node.
- In Delivery, both `Internal Delivery Webhook` and `Execute Workflow Trigger` feed `Validate & Normalize`.
- The normal send path reaches node `MailerSend Send`, which POSTs to Supabase function `/functions/v1/henvalt-mailersend-delivery`.

### 2. Separate one-off test sender

- The active Delivery workflow also contains a separate manual-trigger branch:
  `One-Off Test Email Trigger` → `Prepare One-Off Test Delivery` → `One-Off Test Authorized?` → `MailerSend One-Off Test Email` → `Record One-Off Test Result`.
- `MailerSend One-Off Test Email` independently POSTs to the same `henvalt-mailersend-delivery` Edge Function.
- The preparation node contains a hard-coded delivery-request UUID and a hard-coded recipient address in its request body. These values are intentionally omitted from this report to avoid reproducing personal data.
- This branch is distinct from Recovery's `HENVALT One-Off Email Preview`, which is a preview-only path and does not itself send.
- Because this is a manual trigger, it is not an ordinary public webhook; however, it remains a separately executable send-capable workflow branch and must be included in the cutover test inventory.

## Confirmed provider boundary

- Supabase project `ocyplckdojdubyrsxcxa` has active Edge Function `henvalt-mailersend-delivery`, version 1, `verify_jwt=true`.
- Previously inspected production source sends directly to MailerSend's `/v1/email` endpoint and does not contain the candidate V1 readiness interlock.
- Candidate repository source includes a fail-closed readiness check, but it has not been deployed to production.
- The live `henvalt-mailersend-setup` Edge Function is version 8 and returns HTTP 410 with `managed_provider_only`; it does not send email.

## Edge Function inventory scan

The complete active Supabase Edge Function inventory was inspected. Across the 16 active functions other than `henvalt-mailersend-delivery`, source scans found no direct MailerSend `api.mailersend.com/v1/email` endpoint or matching direct provider-send endpoint. The scanned functions include the Shopify OAuth/control-plane, pixel-ingest, dashboard, sender-profile/branding, privacy, AI, and mail setup/public-action functions.

This narrows the direct Supabase Edge Function provider-send boundary to `henvalt-mailersend-delivery` based on the source snapshot inspected. It does not prove the absence of other delivery mechanisms outside this Supabase project or outside the inspected n8n workflows.

## Cutover implications

1. The interlock must be verified at the provider boundary in `henvalt-mailersend-delivery`, so both n8n call paths fail closed.
2. The acceptance matrix must separately exercise the normal webhook handoff, Execute Workflow invocation, and manual one-off test branch without actually contacting MailerSend.
3. Tracking, unsubscribe, MailerSend event, and inbound-reply webhooks are non-send functions and should remain available; disabling all Delivery webhooks would impair suppression and event processing.
4. The hard-coded one-off test recipient/request data requires a separate retention/redaction review and should not be copied into further evidence artifacts.
5. No production changes are authorized by this report. Do not deploy, activate a readiness flag, edit active workflows, or run live send paths until explicit production approval.

## Remaining evidence gaps

- Effective n8n instance-level execution retention/pruning and redaction configuration has not yet been independently established.
- Runtime proof that every send-capable branch is blocked remains pending deployment approval and a safe isolated test environment.
- The complete acceptance matrix has not yet been rerun against an isolated staging deployment.
