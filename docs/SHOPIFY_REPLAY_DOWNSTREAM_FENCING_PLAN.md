# Shopify replay downstream fencing — candidate implementation plan

Status: read-only production audit + candidate design. No production database, active n8n workflow, Edge Function, Worker, or Shopify app was changed.

## Verification checkpoint

- Candidate branch: `work/48h-system-readiness-2026-11-21`.
- Safety workflow run `44892041223`: completed successfully. The job `interlock-tests` passed all steps, including static safety invariants, Edge Function type checks, disposable PostgreSQL 17 migrations through candidate migration 008, atomic ingress/replay acceptance, lease-expiry/stale-worker acceptance, and deny/allow/audit/consent/fail-closed tests.
- This proves the tested candidate contracts on disposable PostgreSQL. It does not prove live production deployment or end-to-end Shopify recovery.

## Why queue fencing is not sufficient

Migration 008 fences the queue boundary:
- claim issues a lease UUID and expiry;
- load, renew, retry, and complete require the current worker + lease tuple;
- reclaim replaces the old lease;
- expired final-attempt jobs are dead-lettered.

The worker contract also requires a heartbeat before every mutating stage. That is a cooperative stop rule, not a database transaction fence. A worker can pass a heartbeat, pause, lose its lease, then resume an in-flight business write unless that write validates the lease in the same database transaction.

## Production function inventory confirmed by read-only catalog inspection

The live `henvalt` schema contains these mutation-capable RPCs relevant to the Shopify event projection path:

| Function | Current signature | Mutation boundary to review |
|---|---|---|
| `upsert_canonical_event` | tenant, webhook event, event fields, payload, metadata, idempotency, correlation | canonical event insert |
| `upsert_customer` | tenant, Shopify customer ID, identity/contact/consent fields, metadata | customer insert/update |
| `upsert_checkout` | tenant, Shopify checkout ID, customer, token/session, email, value/currency/status, metadata | checkout insert/update |
| `create_opportunity_idempotent` | tenant, source event, customer, checkout, type/value/currency/score/idempotency/expiry/correlation | opportunity insert/update |
| `project_order_from_event` | canonical event ID | order insert/update and projection |
| `apply_shopify_email_consent_update` | tenant, Shopify customer ID/email, consent, metadata | customer + suppression + opportunity + delivery + intervention + sequence updates |

Additional functions found by the same catalog scan include `create_intervention`, `create_revenue_adjustment`, and `post_recovery_to_ledger`. These are downstream business-write boundaries and must be included only if the replay path can reach them. Their caller graph and exact use in the Shopify replay path remain to be mapped before implementation.

The scheduled candidate processors `process_abandoned_cart_candidates`, `process_abandoned_checkout_candidates`, and `process_browse_abandonment_candidates` also mutate opportunities and may enqueue interventions. They are scheduled recovery processors, not automatically safe to call from a webhook replay subflow; do not wire them into replay without an explicit event-to-projection design.

## Required implementation shape

1. Introduce one private lease assertion primitive that validates, in the caller's transaction:
   - job ID;
   - worker ID;
   - lease UUID;
   - unexpired lease;
   - current CLAIMED state and expected replay job type;
   - tenant binding between the replay job and stored webhook.
2. Carry the exact lease tuple from the replay claim through every replay-specific mutating RPC. Each RPC must call the assertion before its first write, in the same transaction as the write.
3. Do not accept a caller-supplied tenant ID as authority. Derive tenant and webhook identity from the locked replay job/webhook rows.
4. Preserve non-replay call paths only through explicit, separately reviewed internal entry points. Do not leave a service-role-callable legacy signature that lets the replay worker bypass lease validation.
5. Lock rows in a consistent order (job, webhook, then tenant-owned projection rows) and keep transactions bounded. Avoid holding a lease-row lock across network calls.
6. Keep the existing three-workflow architecture. The replay path stays in `HENVALT_RECOVERY` / its `HENVALT_INGEST` replay subflow; no fourth workflow.
7. Do not attempt a blanket change to every business RPC until the actual replay call graph is mapped from the active workflow and Edge Function code. In particular, consent updates and order attribution may be invoked through separate webhook topics and require their own explicit path mapping.

## Required acceptance tests before staging

The disposable PostgreSQL acceptance suite must prove all of the following, using actual business tables and actual replay RPC signatures:

- Current lease: a replay worker can write the expected canonical event/projection.
- Expiry before call: a stale worker is rejected and no business row changes.
- Reclaim before call: worker A's lease is replaced by worker B's lease; worker A cannot write.
- Expiry during a simulated gap: worker A pauses after an earlier successful stage; worker B reclaims; worker A's next business RPC is rejected.
- Tenant binding: a lease for tenant A cannot mutate tenant B rows, even if a foreign row ID is supplied.
- Idempotent retry: worker B can safely resume without duplicate canonical events, customers, checkouts, opportunities, orders, interventions, attributions, or ledger entries.
- Legacy bypass: service_role cannot invoke any replay-reachable legacy mutation signature that omits the lease tuple.
- Non-replay regression: separately authorized non-replay callers continue to work without weakening replay fencing.
- Rollback: a failed downstream stage leaves no partial writes from that stage.

A passing queue-only test is not sufficient. A passing heartbeat-only static test is not sufficient.

## Open mapping work before writing migration 009

- Export and inspect the active `HENVALT_INGEST` node graph and all HTTP/RPC calls in the actual replay processing path.
- Inspect the deployed `henvalt-shopify-oauth` / webhook projection Edge Function source, if any, and identify every database RPC it calls.
- Map Shopify topics to their concrete projection functions (orders, checkout, customer consent, cart, pixel).
- Trace the internal callers of each candidate mutation RPC before changing signatures or grants.
- Produce a complete caller inventory and migration compatibility plan, then implement migration 009 plus real stale-worker business-write tests.

## Safety boundary

Production is read-only for this work. No candidate migration has been applied to the production project. No live workflow has been edited or published. No provider call or email was made. No PR was merged and no app/Worker release was performed.
