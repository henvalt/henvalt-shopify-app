import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const cutover = readFileSync(
  "docs/ACTIVE_WORKFLOW_CUTOVER_BLOCKERS_2026-11-21.md",
  "utf8",
);
const worker = readFileSync(
  "docs/N8N_SHOPIFY_WEBHOOK_REPLAY_WORKER_CANDIDATE.md",
  "utf8",
);
const migration = readFileSync(
  "supabase/migrations/202611210009_shopify_replay_business_write_fencing.sql",
  "utf8",
);

test("cutover contract preserves exactly the three existing workflow identities", () => {
  for (const name of ["HENVALT_INGEST", "HENVALT_RECOVERY", "HENVALT_DELIVERY"]) {
    assert.ok(cutover.includes(name), `missing workflow identity: ${name}`);
  }
  assert.match(cutover, /no fourth workflow/i);
  assert.match(cutover, /active n8n versions.*remain unchanged/i);
});

test("ingress must not acknowledge before durable Shopify queue acceptance", () => {
  assert.match(cutover, /responseMode: onReceived/);
  assert.match(cutover, /explicit response handling, not `onReceived`/);
  assert.match(cutover, /durable acceptance/);
  assert.match(cutover, /exactly one explicit response/i);
  assert.match(cutover, /Shopify events must terminate/i);
});

test("replay processing requires transaction-local fenced wrappers, not heartbeat alone", () => {
  assert.match(cutover, /transaction-local wrappers/);
  assert.match(cutover, /Never call the unfenced equivalent/);
  assert.match(worker, /Authoritative correction — transactional fencing supersedes heartbeat-only wording/);
  assert.match(worker, /MUST call the migration 009/);
  assert.match(migration, /FOR UPDATE/);
  for (const name of [
    "upsert_customer_fenced",
    "resolve_identity_fenced",
    "upsert_canonical_event_fenced",
    "upsert_checkout_fenced",
    "create_opportunity_idempotent_fenced",
    "create_intervention_and_enqueue_fenced",
    "project_order_from_event_fenced",
    "evaluate_order_attribution_fenced",
    "create_revenue_adjustment_fenced",
    "process_shopify_revenue_adjustment_fenced",
    "deactivate_shopify_connection_on_uninstall_fenced",
    "stop_recovery_after_order_fenced",
    "mark_webhook_processed_fenced",
    "mark_webhook_failed_fenced",
  ]) {
    assert.ok(migration.includes(name), `migration missing wrapper: ${name}`);
    assert.ok(worker.includes(name), `worker contract missing wrapper: ${name}`);
  }
});

test("provider-send acceptance remains default-deny for both delivery entry points", () => {
  assert.match(cutover, /ordinary send and manual one-off test send/i);
  assert.match(cutover, /one-off test route must remain denied/i);
  assert.match(cutover, /Do not open the interlock/i);
  assert.match(cutover, /network-denied stub/i);
});

test("production release is explicitly blocked pending isolated staging acceptance", () => {
  assert.match(cutover, /NO-GO for production launch/);
  assert.match(cutover, /Do not restore a paused project or create a branch\/project until cost is known/i);
  assert.match(cutover, /explicit release decision/i);
});
