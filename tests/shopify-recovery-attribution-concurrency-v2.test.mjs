import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const workflow=readFileSync(new URL("../.github/workflows/shopify-identity-v2-validation.yml",import.meta.url),"utf8");
const setup=readFileSync(new URL("./sql/shopify-recovery-attribution-concurrency-setup-v2.test.sql",import.meta.url),"utf8");
const runner=readFileSync(new URL("./sql/shopify-recovery-attribution-concurrency-v2.test.sh",import.meta.url),"utf8");
const attribution=readFileSync(new URL("../supabase/migrations/202611170012_shopify_recovery_attribution_fee_ledger_v2.sql",import.meta.url),"utf8");

test("attribution concurrency fixture forces two evaluators to race at the unique insert",()=>{
  assert.match(setup,/test_attribution_race_fixture_v2/);
  assert.match(setup,/CREATE TRIGGER test_attribution_race_barrier_v2[\s\S]*?BEFORE INSERT ON henvalt\.shopify_recovery_attributions_v2/);
  assert.match(setup,/pg_catalog\.pg_sleep\(1\.5\)/);
  assert.match(setup,/889001/);
  assert.match(setup,/889004/);
  assert.match(setup,/set_shopify_recovery_attribution_policy_v2\([\s\S]*?false/);
  assert.match(setup,/set_shopify_recovery_attribution_policy_v2\([\s\S]*?true/);
});

test("two independent PostgreSQL sessions require one winner and explicit conflict loser",()=>{
  assert.match(runner,/evaluate_shopify_recovery_attribution_v2\(order_a_id\)/);
  assert.match(runner,/evaluate_shopify_recovery_attribution_v2\(order_b_id\)/);
  assert.match(runner,/\$pid_a/);
  assert.match(runner,/\$pid_b/);
  assert.match(runner,/OPPORTUNITY_ALREADY_ATTRIBUTED/);
  assert.match(runner,/accepted_count/);
  assert.match(runner,/rejected_count/);
  assert.match(runner,/"1:1:1:1"/);
  assert.match(runner,/shopify_recovery_fee_measurements_v2/);
});

test("the exact-store identity CI workflow executes setup and concurrent race runner",()=>{
  assert.match(workflow,/Prepare deterministic competing-order attribution race[\s\S]*?shopify-recovery-attribution-concurrency-setup-v2\.test\.sql/);
  assert.match(workflow,/Exercise two-session exact-store attribution race[\s\S]*?shopify-recovery-attribution-concurrency-v2\.test\.sh/);
});

test("the production evaluator retains the explicit unique-conflict rejection path",()=>{
  assert.match(attribution,/ON CONFLICT DO NOTHING[\s\S]*?OPPORTUNITY_ALREADY_ATTRIBUTED/);
});
