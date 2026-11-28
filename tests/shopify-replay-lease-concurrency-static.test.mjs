import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const heartbeat = readFileSync(
  "supabase/migrations/202611210011_shopify_replay_write_lease_heartbeat.sql",
  "utf8",
);
const claim = readFileSync(
  "supabase/migrations/202611210008_shopify_replay_lease_fencing.sql",
  "utf8",
);
const harness = readFileSync(
  "tests/shopify-replay-lease-concurrency-postgres.sh",
  "utf8",
);
const workflow = readFileSync(
  ".github/workflows/provider-send-interlock-static.yml",
  "utf8",
);

test("write guard locks the job row and commits lease renewal in the caller transaction", () => {
  assert.match(heartbeat, /lease_expires_at > clock_timestamp\(\)[\s\S]*?FOR UPDATE/);
  assert.match(heartbeat, /UPDATE henvalt\.background_jobs[\s\S]*?lease_expires_at = clock_timestamp\(\) \+ interval '180 seconds'/);
  assert.match(heartbeat, /The row lock prevents another worker from reclaiming/);
});

test("claim uses SKIP LOCKED when considering expired leases", () => {
  assert.match(claim, /j\.status = 'CLAIMED'::henvalt\.job_status[\s\S]*?j\.lease_expires_at <= now\(\)[\s\S]*?FOR UPDATE SKIP LOCKED/);
});

test("two-session acceptance holds the write lock beyond the original committed expiry", () => {
  assert.match(harness, /assert_shopify_replay_lease_for_write/);
  assert.match(harness, /pg_sleep\(12\)/);
  assert.match(harness, /sleep 7/);
  assert.match(harness, /race-contender/);
  assert.match(harness, /CONCURRENT_RECLAIM_BYPASSED_ACTIVE_WRITE_LOCK/);
  assert.match(harness, /race-after-commit/);
  assert.match(harness, /SHOPIFY_REPLAY_LEASE_CONCURRENCY_ACCEPTANCE_PASSED/);
});

test("concurrency acceptance is part of the PostgreSQL safety workflow", () => {
  assert.match(workflow, /shopify-replay-lease-concurrency-postgres\.sh/);
});
