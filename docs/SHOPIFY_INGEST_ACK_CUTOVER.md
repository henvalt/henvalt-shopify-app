# Shopify ingress acknowledgement cutover

Status: **release blocker identified by read-only inspection**. This is a candidate-only cutover specification; it does not change the active n8n workflow.

## Observed active configuration

Read-only inspection of active workflow `HENVALT_INGEST` (workflow ID `VTpfGKNtu1CSQ4Rv`, active version `6368d539-708f-494a-8be8-b9601d0e8607`) found:

- Webhook path: `POST /henvalt/ingest`
- `rawBody: true`
- `responseMode: onReceived`
- No `Respond to Webhook` node in the active workflow.
- The current path is normalization → HMAC verification → Shopify tenant resolution → tenant binding/validation → `ingest_raw_webhook_v2` → `Classify Result` → `Should Process?`.
- The current `HMAC Verified?` false output has no connected response node.
- The current `Is Valid` false output reaches `Reject Invalid Event` (`stopAndError`), not an HTTP response node.

The Cloudflare ingress worker waits for the n8n HTTP response. With `onReceived`, n8n can acknowledge the HTTP request before HMAC verification and before `ingest_raw_webhook_v2` has durably accepted the event. A later n8n failure therefore cannot be communicated to Shopify as a retryable HTTP failure. This is an event-loss/retryability risk, even though the worker's HMAC check has already succeeded.

## Required candidate workflow change

Do not edit the active workflow without explicit approval and a controlled change window.

Build and validate this topology in an isolated staging workflow first:

1. Preserve the active workflow export/version and current webhook configuration.
2. Change the staging webhook response mode to `responseNode`.
3. Add one shared `Respond to Webhook` node named `Acknowledge Ingress Request`.
4. Successful ingest path: keep `Classify Result` as the success-envelope builder, then route `Classify Result` → `Acknowledge Ingress Request` → `Should Process?`. The response node must send the classifier's `__http` and `__body`, then allow execution to continue.
5. Add a rejection-envelope builder for pre-ingest failures. Route the false output of `HMAC Verified?` into it with HTTP 401. Route the false output of `Is Valid` into it and classify the failure:
   - tenant lookup infrastructure/RPC error (`__tenant_lookup_error`): HTTP 503;
   - verified Shopify shop with no tenant mapping (`__tenant_mapping_missing`): HTTP 404;
   - malformed or incomplete event: HTTP 422.
6. Connect the rejection-envelope builder to the same `Acknowledge Ingress Request` node. Replace the current `Reject Invalid Event` stop/error response path in staging; do not leave any webhook-triggered branch without a response path.
7. For accepted events, return HTTP 200 only when `ingest_raw_webhook_v2` returns a successful HTTP status, a non-empty `webhook_id`, and an explicit boolean `should_process` decision. Missing ID/decision, RPC timeout, network error, or Supabase 5xx must return HTTP 503. The current classifier has a separate generic HTTP 409 shortcut that returns `duplicate`/200 without proving a durable `webhook_id`; remove that shortcut or make it return 503 unless a durable row ID and explicit processing state are present.
8. Preserve duplicate semantics: already-processed and currently-processing duplicates return HTTP 200 without re-running canonical processing. A durable newly accepted row returns HTTP 200, after which execution continues through `Should Process?` and downstream processing.
9. Preserve existing post-ack failure marking and stale-work repair. Verify that an error after durable acceptance can be recovered from the persisted webhook row; a post-ack error cannot be converted into a Shopify retry because the HTTP response has already been sent.
10. Verify exactly one response is sent for every path. Test valid HMAC, invalid HMAC, unknown shop, tenant lookup timeout, malformed event, ingest RPC 5xx/timeout, missing webhook ID, missing processing decision, new accepted event, processed duplicate, processing duplicate, and post-ack processing failure.


## Read-only database contract verification

The connected production database was inspected with SELECT-only catalog/function-definition queries; no data or schema was changed:

- `henvalt.verify_shopify_webhook_hmac(text,text)` returns a boolean and its execute ACL is limited to `service_role` and `postgres`.
- `henvalt.resolve_shopify_tenant(text)` returns a UUID or NULL for an unmapped/inactive shop; its execute ACL is limited to `service_role` and `postgres`.
- `henvalt.ingest_raw_webhook_v2(...)` returns `webhook_id`, `is_duplicate`, `should_process`, and `processing_status`; its execute ACL is limited to `service_role` and `postgres`.
- The ingest RPC locks matching idempotency rows, returns completed/in-flight duplicate decisions, and inserts a new row with `PROCESSING` state before returning. PostgREST's successful RPC response therefore provides the durable row identity needed before HTTP acknowledgement.
- These database contracts support the proposed acknowledgement boundary, but they do not fix the current n8n response mode or the classifier's generic 409 shortcut.

## Acceptance matrix

| Scenario | Expected response | Requirement |
|---|---:|---|
| New webhook accepted by ingest RPC | 200 | Durable row + webhook ID + explicit decision first |
| Duplicate already processed | 200 | Existing durable row |
| Duplicate currently processing | 200 | Existing durable row |
| Invalid HMAC | 401 | Reject before tenant lookup/ingest |
| Tenant mapping missing | 404 | HMAC verified; no tenant guessed |
| Tenant lookup infrastructure failure | 503 | Retryable; do not mislabel as unknown tenant |
| Malformed/incomplete event | 422 | Explicit rejection response |
| Ingest RPC unavailable / timeout / 5xx | 503 | No success acknowledgement |
| Ingest RPC omits webhook ID or decision | 503 | Fail closed |\n| Generic HTTP 409 without durable webhook ID | 503 | Never infer duplicate from status code alone |
| Downstream processing fails after 200 | Already acknowledged | Durable row must be repairable/replayable |

## Implementation cautions

- Do not put the shared response node only after `Classify Result`: that misses the current HMAC-false and validation-false branches.
- Do not use `stopAndError` for a webhook branch that must return a defined HTTP status.
- Do not return 200 for an RPC response that lacks the durable webhook ID or explicit processing decision.\n- Do not treat a generic HTTP 409 as a duplicate unless the RPC response includes the durable webhook ID and explicit processing decision.
- Confirm the n8n version's Respond to Webhook continuation behavior in staging; the intended topology is response first, then continue downstream processing.
- Confirm a single HTTP response per execution when success and rejection routes converge.

## Safety boundary

This is documentation, contract code, and candidate regression tests only. No production n8n workflow, Supabase object, Cloudflare Worker, Shopify app release, or email sender was changed.
