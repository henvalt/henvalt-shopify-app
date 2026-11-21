# Shopify ingress acknowledgement cutover

Status: **release blocker identified by read-only inspection**. This document is a candidate-only cutover specification; it does not change the active n8n workflow.

## Observed active configuration

Read-only inspection of active workflow `HENVALT_INGEST` (workflow ID `VTpfGKNtu1CSQ4Rv`, active version `6368d539-708f-494a-8be8-b9601d0e8607`) found:

- Webhook path: `POST /henvalt/ingest`
- `rawBody: true`
- `responseMode: onReceived`
- No `Respond to Webhook` node in the active workflow.
- The first processing nodes after the webhook are normalization, configuration, HMAC verification, tenant resolution, and the durable Supabase ingest RPC.

The Cloudflare ingress worker waits for the n8n HTTP response. With `onReceived`, n8n can acknowledge the HTTP request before HMAC verification and before `ingest_raw_webhook_v2` has durably accepted the event. A later n8n failure therefore cannot be communicated to Shopify as a retryable HTTP failure. This is an event-loss/retryability risk, even though the worker's HMAC check has already succeeded.

## Required candidate workflow change

Do not edit the active workflow without explicit approval and a controlled change window.

1. Export and preserve the active workflow version and its current webhook configuration.
2. In an isolated staging workflow, change the webhook response mode to `responseNode`.
3. Add one `Respond to Webhook` node immediately after `Classify Result` and before `Should Process?`.
4. Respond using the classifier's `__http` and `__body` values. The classifier already distinguishes:
   - accepted new durable webhook row: HTTP 200;
   - already-processed / currently-processing duplicate: HTTP 200;
   - missing webhook ID or missing processing decision: HTTP 503;
   - invalid tenant/authentication: HTTP 401/404;
   - transient Supabase / RPC failure: HTTP 503.
5. Continue the workflow from the Respond node to `Should Process?`. A newly accepted row continues through canonical event processing; a duplicate exits without reprocessing.
6. Confirm the raw webhook row is durably committed before the response node can run. If the RPC returns an error or no webhook ID, return 503 so Shopify retries.
7. Exercise all response branches with synthetic signed requests in isolated staging. Confirm a 200 is never sent before durable acceptance, and that a retry of the same webhook ID is idempotent.
8. Preserve the existing failure marking and stale-work repair path. Confirm a post-ack processing failure remains recoverable from the durable webhook row.

## Acceptance matrix

| Scenario | Expected response | Must be durable first? |
|---|---:|---|
| New webhook accepted by ingest RPC | 200 | Yes |
| Duplicate already processed | 200 | Existing row |
| Duplicate currently processing | 200 | Existing row |
| HMAC invalid | 401 | No |
| Tenant mapping missing | 404 | No |
| Ingest RPC unavailable / timeout | 503 | No |
| Ingest RPC omits webhook ID or decision | 503 | No |

## Safety boundary

This is documentation and a proposed staging acceptance contract only. No production n8n workflow, Supabase object, Cloudflare Worker, Shopify app release, or email sender was changed.
