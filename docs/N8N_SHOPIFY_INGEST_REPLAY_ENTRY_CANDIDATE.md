# HENVALT_INGEST replay entry — candidate contract

Status: candidate-only engineering specification and pure helpers. This is not an importable n8n workflow, does not modify a live workflow, and is not staging evidence.

## Fixed identities and safety

- Existing workflow: `HENVALT_INGEST`, ID `VTpfGKNtu1CSQ4Rv`.
- Inspected published version: `6368d539-708f-494a-8be8-b9601d0e8607`.
- Keep the system at exactly three workflows: `HENVALT_INGEST`, `HENVALT_RECOVERY`, and `HENVALT_DELIVERY`.
- No active workflow edits, publishing, execution, production database changes, provider sends, or new workflow creation are authorized by this candidate.

## Correct replay loader contract

The authoritative migration 008 signature is:

```sql
henvalt.load_shopify_webhook_replay_job(
  p_job_id uuid,
  p_worker_id text,
  p_lease_id uuid
)
```

The earlier two-argument loader is revoked from `service_role`. A replay entry must receive the three claim fields from the recovery workflow and call the three-argument loader. The returned row includes `job_id`, `webhook_id`, `tenant_id`, `source_event_id`, `topic`, `payload`, `metadata`, `processing_status`, `webhook_processed`, `correlation_id`, and `lease_expires_at`. The loader does not return the lease ID; preserve it from the claim result.

## Envelope and trusted context

`n8n/shopify-ingest-replay-envelope-candidate.mjs` is a pure helper that accepts only the claim row and lease-bound loaded row. It requires:
- Exact job ID equality between claim and load.
- Nonblank worker ID and a UUID lease ID.
- UUID webhook and tenant IDs.
- Nonempty delivery ID and topic.
- A plain object payload.
- `metadata.ingress_hmac_verified === true`.
- A valid `*.myshopify.com` domain.
- `metadata.shopify_webhook_id === source_event_id`.
- An unexpired lease and replayable webhook state.

It reconstructs the normalizer input as `body`, `headers`, and `query`. The canonical `body.event_id` is the stored Shopify delivery ID (`source_event_id`), not `X-Shopify-Event-Id` or the payload entity `id`. The exact lease tuple and stored tenant ID are placed in a separate top-level `replay_context`, never in the Shopify payload. The normalizer candidate graph must copy only that top-level property into its output. Public Shopify webhook JSON is nested under `body`, so a caller cannot populate this top-level worker context through the webhook body.

The replay path may bypass a second external HMAC call only after the lease-fenced loader proves the durable row carries the ingress HMAC attestation. It must still resolve the shop domain through the existing tenant lookup and compare the resolved tenant ID with the stored `replay_context.tenant_id` before entering any mutation node.

## Shared processing graph

Candidate graph wiring should use the existing normalizer, event-class configuration, tenant lookup, tenant binding, classifier, and business pipeline. The dedicated Execute Workflow Trigger accepts only `job_id`, `worker_id`, and `lease_id`. The replay loader and envelope helper reconstruct trusted event context. A tenant equality guard is required before replay work reaches the common classifier.

The common classifier needs two explicit inputs:
1. Public ingress: the result from `receive_shopify_webhook_v1`, accepted only after durable webhook and active replay job IDs are confirmed.
2. Replay subflow: the validated loaded webhook and tenant-bound lease context, which sets the existing downstream `__proceed` and `__webhook_id` fields.

The replay branch must not call the public ingress RPC again, because that would enqueue/claim a second replay job. It must not continue through the old unfenced inline processing path.

## Write-boundary requirements

All 18 observed mutating operations in `n8n/shopify-ingest-replay-write-map.json` must dispatch to their matching `*_fenced` wrapper whenever replay context is present. The exact tuple `job_id + worker_id + lease_id` is the first three arguments. Every write remains sequential. A replay branch must never call the unfenced counterpart. The processed and failed webhook markers must use `mark_webhook_processed_fenced` and `mark_webhook_failed_fenced`.

The existing workflow's raw error capture must not write customer data or exception text into replay queue error fields. Replay retry reasons should remain constant and non-PII.

## Durable ingress acknowledgement

The public Shopify path must call `henvalt.receive_shopify_webhook_v1`, which verifies the raw-body HMAC, resolves the tenant, and transactionally persists the webhook and replay job. The workflow must classify the explicit RPC row and use exactly one Respond to Webhook node per request. A 200 is allowed only for:
- `accepted` / `replay_accepted` with a UUID webhook ID, UUID replay job ID, and active job state.
- `duplicate` with the webhook already `PROCESSED`.

Missing IDs, an unknown result, a terminal job, an old generic 409, or a transport failure must not be represented as durable acceptance; return 503. After the explicit response, Shopify ingress must terminate and must not continue into the old inline mutation pipeline.

`n8n/shopify-ingest-ack-classifier-candidate.mjs` implements this fail-closed decision. It is a pure classifier, not a live n8n node.

## Deferred payment reconciliation handoff — verified active recovery path

The live production function `defer_payment_webhook_reconciliation(uuid,text)` marks the webhook `FAILED`, sets `payment_reconciliation_pending=true`, and schedules `payment_reconciliation_next_at`. The active `HENVALT_RECOVERY` workflow (version `32e50bf7-4cbd-4070-bbba-f259ed17b369`) has an `Every Minute` trigger connected to `Reconcile Deferred Payment Webhooks`, which calls `henvalt.reconcile_deferred_payment_webhooks(10)`. Read-only production catalog inspection confirms that reconciler selects due FAILED rows with `payment_reconciliation_pending=true` using `FOR UPDATE SKIP LOCKED`, then marks them PROCESSED, reschedules retry, or dead-letters after 60 attempts. Therefore, a successful `defer_payment_webhook_reconciliation_fenced(...)=true` is a durable terminal handoff for the replay job, although the webhook itself remains FAILED pending its separate reconciler. The candidate replay result must expose `deferred_payment_handoff=true` only on a true fenced RPC result; the recovery worker may complete the replay job on either `mark_webhook_processed===true` or this verified handoff flag. Add isolated acceptance proving the handoff and later reconciler pickup. Do not treat a false/ambiguous RPC result as success.

## Acceptance and release boundary

Static checks cover the envelope, durable acknowledgement classifier, loader signature, write-map inventory, and no-provider route. They do not prove an n8n graph has been authored, imported, or executed. Before staging, build a complete isolated workflow JSON candidate, audit every mutation node, resolve the deferred-payment branch, and run the full replay matrix against disposable PostgreSQL with provider egress denied.

Production remains NO-GO until isolated staging proves durable ingress, replay, lease replacement, all fenced writes, terminal status, and end-to-end event-to-ledger behavior. Provider sending stays disabled.
