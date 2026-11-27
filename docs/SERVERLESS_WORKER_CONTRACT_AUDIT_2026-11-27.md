# HENVALT serverless worker contract audit — 27 November 2026

**Decision: NO-GO for recovery/delivery runtime deployment.** This is a read-only staging contract audit. No SQL, secrets, functions, Workers, schedules, Shopify registrations, email, or billing were changed.

**Target:** `henvalt-integrated-staging` (`xidhtmrfvsgfmyltjuja`)  
**Candidate branch:** `feat/shopify-connection-scoped-ingress`  
**PR:** #15

## 1. What exists in staging now

- The staging database is healthy and has the connection-scope candidate migrations applied.
- `henvalt.receive_shopify_webhook_v1` exists and is executable by `service_role`; it is not executable by `anon` or `authenticated`.
- The durable job table `henvalt.background_jobs` is empty: zero rows across all job types and statuses.
- `henvalt.provider_sending_is_enabled()` remains false.
- Only `henvalt-merchant-dashboard` is deployed as an Edge Function. The OAuth and webhook-ingress Edge Functions are not deployed.
- No recovery, delivery, or ingest schedule is configured. Prior runtime audit also found no `pg_net` extension and no usable Cloudflare Cron deployment.
- The one Shopify connection row is only a fixture: no numeric Shopify shop ID, scopes, or token references. There are zero Auth users and no real installed store.
- No real event, delivery request, or recovery ledger lifecycle is present in staging.

## 2. Verified database worker contracts

The staging database exposes these existing service-role worker operations:

| Stage | Existing database contract | Important condition |
|---|---|---|
| INGEST | `receive_shopify_webhook_v1` | Verifies Shopify HMAC and persists webhook/replay job atomically; ingress must acknowledge only confirmed durable acceptance |
| INGEST replay | `claim_shopify_replay_job`, `load_shopify_webhook_replay_job`, `complete_shopify_replay_job`, `retry_shopify_replay_job` | Replay uses a lease ID; writes must retain the same job/worker/lease identity |
| RECOVERY | `claim_next_job`, `get_recovery_worker_context`, `create_recovery_sequence_fenced` | Generic claim stores worker ID and timestamp; sequence creation has an explicit replay-job fence |
| DELIVERY | `load_delivery_retry_envelope`, `authorize_delivery_request`, `mark_mailersend_provider_egress_started`, `record_delivery_result` | Retry envelope validates job identity and a 900-second claim age; provider egress rechecks intervention/request state and the global send interlock |
| Lifecycle | `complete_job`, `retry_job`, `dead_letter_job`, `requeue_stale_jobs` | Generic completion is worker-ID fenced; stale delivery with a non-pending request is dead-lettered for manual reconciliation |

### Implementation implications

1. Do not use `claim_next_job` as if it returned a lease token. Its current signature is `(p_worker_id text, p_job_types text[])`; it updates `status`, `attempts`, `locked_at`, and `locked_by`, but does not issue a lease ID.
2. The Shopify replay path is separately lease-fenced. Do not collapse it into the generic queue path or drop `lease_id` from replay calls.
3. Delivery retry jobs are a distinct job type, `execute_delivery_retry_generation`, with payload identity for tenant, intervention, delivery request, and generation. The retry loader checks all of those values.
4. The provider egress marker is the last database authorization gate before a MailerSend request. A delivery worker must not call MailerSend before that RPC returns true.
5. If a worker times out after provider acceptance, it must preserve the ambiguous state and reconcile; it must not blindly create another send.
6. The generic stale-job reaper treats an `execute_intervention` job with an already non-pending delivery request as ambiguous and moves it to dead letter rather than resending.

## 3. Staging security advisor interpretation

The Supabase security advisor reports 19 RLS-enabled tables in the private `henvalt` schema with no policies. The read-only privilege check found:

- `anon` has no `USAGE` on schema `henvalt`.
- `authenticated` has schema `USAGE`, but no table privileges in `henvalt`.
- `service_role` has the table privileges needed by the server-side application.
- No `anon` or `authenticated` table SELECT grant was found in `henvalt`.

Therefore the advisor findings are not evidence that those tables are publicly readable. Do not silence them with blanket policies or broaden grants. Keep the schema private and service-role-only; separately verify every RPC's EXECUTE grants and SECURITY DEFINER checks before exposing any new endpoint.

## 4. Why no worker code was deployed

The database contracts exist, but the runtime prerequisites do not. A worker deployment would be unsafe to call complete without:

- an owner-controlled staging Shopify app Client ID and app secret;
- the staging Vault secret `henvalt_shopify_app_secret`;
- a fresh shared secret provisioned in both Cloudflare and Supabase;
- the staging OAuth Edge Function deployed and configured;
- the ingress Worker deployed with its staging hostname enabled;
- an owner-controlled Shopify development store and install;
- end-to-end proof of replay → canonical event → opportunity → recovery sequence → intervention → delivery generation, using a network-denied email stub.

The current database contains no queued work to exercise a recovery or delivery worker. Building a speculative handler without pinning every queue payload and lease contract would create a false sense of readiness.

## 5. Next engineering sequence

1. Finish and review the staging OAuth deployment package without deploying it.
2. Provision staging-only credentials and Vault material once the owner supplies the app credentials.
3. Deploy the staging webhook ingress and verify its health endpoint and shared-secret boundary.
4. Install on the owner-controlled development store and deliver one signed synthetic webhook.
5. Implement the recovery executor against observed job types and existing fenced RPCs; add unit, SQL acceptance, retry, stale-lock, and tenant-isolation tests.
6. Implement delivery generation with the provider interlock permanently OFF and a network-denied MailerSend adapter; test timeout-after-acceptance and late callback races.
7. Add one scheduler for each of the three logical stages (INGEST, RECOVERY, DELIVERY), without introducing a fourth business workflow.
8. Only after complete no-send acceptance should provider egress, merchant email quotas, uninstall cancellation, consent, and billing be reviewed as separate release gates.

**Release status remains NO-GO.** This audit is a candidate engineering record, not evidence of a live runtime or launch readiness.
