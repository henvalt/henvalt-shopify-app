import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const spec = readFileSync(new URL("../docs/N8N_SHOPIFY_WEBHOOK_REPLAY_WORKER_CANDIDATE.md", import.meta.url), "utf8");
const migration = readFileSync(new URL("../supabase/migrations/202611210008_shopify_replay_lease_fencing.sql", import.meta.url), "utf8");

test("replay recovery passes the fencing lease into the ingest subflow", () => {
  assert.match(spec, /with only `job_id`, `worker_id`, and the exact `lease_id` returned by the claim/i);
  assert.match(spec, /load_shopify_webhook_replay_job\(job_id, worker_id, lease_id\)/);
  assert.match(spec, /revokes the two-argument loader from `service_role`/);
  assert.doesNotMatch(spec, /load_shopify_webhook_replay_job\(job_id, worker_id\)\s+`?again/i);
});

test("replay worker renewal loss is a hard stop before downstream commits", () => {
  assert.match(spec, /renew_shopify_replay_lease\(job_id, worker_id, lease_id, 180\)/);
  assert.match(spec, /If renewal returns NULL, stop processing and do not commit downstream effects/);
});

test("replay worker renews its lease before each sequential mutation stage", () => {
  assert.match(spec, /Before each potentially long-running or mutating pipeline stage[\s\S]*renew the same lease/i);
  assert.match(spec, /Keep stage calls sequential; never fan out mutating work in parallel/i);
  assert.match(spec, /If renewal fails, stop immediately[\s\S]*do not begin another downstream mutation/i);
  assert.match(spec, /Downstream stage RPCs must remain idempotent by tenant \+ source webhook\/event identity/i);
  assert.match(spec, /not itself a transaction lock over all downstream systems/i);
});

test("database loader and terminal operations are lease-fenced", () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.load_shopify_webhook_replay_job\(\s*p_job_id uuid,\s*p_worker_id text,\s*p_lease_id uuid/s);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.complete_shopify_replay_job\(\s*p_job_id uuid, p_worker_id text, p_lease_id uuid/s);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.retry_shopify_replay_job\(\s*p_job_id uuid, p_worker_id text, p_lease_id uuid/s);
  assert.match(migration, /CREATE OR REPLACE FUNCTION henvalt\.renew_shopify_replay_lease\(\s*p_job_id uuid, p_worker_id text, p_lease_id uuid/s);
  assert.match(migration, /shopify_replay_lease_expired_after_max_attempts/);
});
