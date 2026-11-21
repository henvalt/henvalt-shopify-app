# HENVALT_INGEST replay entry — candidate contract

Status: the full offline candidate export has now been generated from the exact pinned active workflow and retained as a CI artifact. It has not been imported into n8n, executed, or validated against an isolated n8n draft. No live workflow was modified.

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

## Deferred payment reconciliation handoff

The candidate routes this operation through `defer_payment_webhook_reconciliation_fenced` and requires an explicit true result before exposing top-level `deferred_payment_handoff=true`. The recovery worker completes the replay job on either `mark_webhook_processed=true` or `deferred_payment_handoff=true`. The webhook itself remains FAILED pending the already-active every-minute reconciler, which claims the durable pending row and processes, reschedules or dead-letters it. This is a durable handoff, not a claim that the webhook is already PROCESSED.

## Acceptance and release boundary

Static checks cover the envelope, durable acknowledgement classifier, loader signature, write-map inventory, and no-provider route. The complete candidate was generated from `n8n/fixtures/henvalt-ingest-active-2026-11-21.sanitized.json`: 68 nodes, 68 unique IDs, 68 unique names, all 18 mutations fenced, no credential references, and no live webhook ID. The candidate artifact is `henvalt-ingest-candidate-no-send` from CI run [44923015914](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44923015914). That run passed all 136 Node tests, both Deno type checks, all disposable PostgreSQL migrations/acceptance tests, and the transactional lease-heartbeat acceptance. Migration `202611210011_shopify_replay_write_lease_heartbeat.sql` now renews the current lease inside every fenced business-write transaction; a stale or expired lease still fails before mutation. The public ingress branch now calls the atomic ingress RPC directly; tenant lookup is reserved for trusted internal replay. A processed event discovered at the second loader boundary returns an idempotent completion flag.

The generated JSON is a raw inactive workflow export with credentials intentionally removed; it still requires credential rebinding and import/schema validation in an approved isolated n8n draft. The recovery graph patch is also still a candidate specification, not an imported workflow. Disposable PostgreSQL is not a substitute for isolated Supabase staging or full n8n runtime acceptance. Production remains NO-GO until staging proves durable ingress, replay, lease replacement, all fenced writes, terminal status, and end-to-end event-to-ledger behavior. Provider sending stays disabled.


## Candidate graph builder and additional guards

`n8n/shopify-ingest-candidate-builder.mjs` transforms a version-pinned workflow export into an offline candidate. It rewrites all 18 audited mutation nodes to select their corresponding `*_fenced` RPC when replay context exists, adds the internal replay trigger and lease-bound loader, adds tenant equality and lease-renewal guards, switches public ingress to `receive_shopify_webhook_v1`, and requires explicit processed/deferred terminal booleans. It also forces Shopify delivery identity to `X-Shopify-Webhook-Id`.

The builder removes credential references from the offline candidate. The Supabase service-role credential must be rebound only in an isolated n8n draft. The fixture-driven regression suite is `tests/shopify-ingest-candidate-builder.test.mjs`. The generated graph has not been imported, executed or validated against a live n8n draft.
