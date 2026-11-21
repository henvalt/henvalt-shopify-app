import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const release = readFileSync(".github/workflows/release-henvalt-8.yml", "utf8");
const config = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");
const identity = readFileSync(".github/workflows/shopify-identity-v2-validation.yml", "utf8");
const runbook = readFileSync("docs/deployment-and-release-runbook-2026-11-18.md", "utf8");
const launchMatrix = readFileSync("docs/launch-readiness-matrix-2026-11-19.md", "utf8");
const cutover = readFileSync("docs/production-cutover-preflight-and-rollback-2026-11-19.md", "utf8");
const n8nBuildSheet = readFileSync("docs/n8n-native-v2-three-workflow-build-sheet-2026-11-19.md", "utf8");
const migrationRegister = readFileSync("docs/migration-compatibility-risk-register-2026-11-19.md", "utf8");
const lineageFoundation = readFileSync("supabase/migrations/202611160007_exact_store_core_lineage_foundation.sql", "utf8");

test("production Shopify release cannot run automatically on push", () => {
  assert.match(release, /workflow_dispatch:/);
  assert.doesNotMatch(release, /^  push:/m);
  assert.match(release, /confirm_release:[\s\S]*?required: true[\s\S]*?type: boolean[\s\S]*?default: false/);
  assert.match(release, /inputs\.confirm_release == true/);
  assert.match(release, /github\.ref == 'refs\/heads\/main'/);
  assert.match(release, /shopify app release/);
});
test("Shopify preparation can create only an unreleased version after manual confirmation", () => {
  assert.match(config, /confirm_shopify_prepare:[\s\S]*?required: true[\s\S]*?type: boolean[\s\S]*?default: false/);
  assert.match(config, /inputs\.confirm_shopify_prepare == true/);
  assert.match(config, /github\.ref == 'refs\/heads\/main'/);
  assert.match(config, /shopify app deploy --no-release/);
});

test("Shopify preparation job has one unambiguous job-level condition", () => {
  const start = config.indexOf("  deploy-shopify-version:");
  const end = config.indexOf("    steps:", start);
  const header = config.slice(start, end);
  assert.equal((header.match(/^    if:/gm) || []).length, 1);
});

test("release documentation tracks the exact candidate migration chain", () => {
  assert.match(identity, /Apply candidate migrations 001 through 062/);
  assert.equal((identity.match(/supabase\/migrations\/[A-Za-z0-9_.-]+\.sql/g) || []).length, 62);
  assert.equal((migrationRegister.match(/^\| \d{2} \|/gm) || []).length, 61);
  const workflowManifest = [...identity.matchAll(/supabase\/migrations\/([A-Za-z0-9_.-]+\.sql)/g)].map(([, name]) => name);
  const registeredManifest = [...migrationRegister.matchAll(/^\| \d{2} \| `([^`]+)`/gm)].map(([, name]) => name);
  assert.equal(new Set(workflowManifest).size, 62);
  assert.deepEqual(registeredManifest, workflowManifest);
  assert.match(migrationRegister, /62 distinct migration paths/);
  assert.match(migrationRegister, /REVIEW REQUIRED — NOT APPROVED FOR PRODUCTION/);
  assert.match(identity, /202611190004_shopify_checkout_candidate_terminal_state_v2\.sql/);
  assert.match(identity, /202611190005_shopify_checkout_provider_submission_gate_v2\.sql/);
  assert.match(identity, /202611190006_shopify_checkout_ambiguous_provider_reconciliation_v2\.sql/);
  assert.match(runbook, /candidate migrations 001–062/i);
  assert.match(runbook, /Candidate migrations 001–062: CI fixture only; not production-applied\./);
  assert.match(launchMatrix, /Candidate migrations 001–062 apply in disposable PostgreSQL CI/);
  assert.doesNotMatch(runbook, /migrations 001–046/);
  assert.doesNotMatch(launchMatrix, /migrations 001–046/);
});

test("three-workflow V2 build contract preserves active V1 runtime and prevents a fourth workflow", () => {
  assert.match(n8nBuildSheet, /Preserve exactly three production workflows/);
  assert.match(n8nBuildSheet, /Do not import this build sheet as a fourth workflow/);
  assert.match(n8nBuildSheet, /Recovery workflow owns the lease because it owns the claim/);
  assert.match(n8nBuildSheet, /must not call the legacy `henvalt-mailersend-delivery`/);
  assert.match(cutover, /HENVALT_INGEST.*VTpfGKNtu1CSQ4Rv.*Active V1/);
  assert.match(cutover, /HENVALT_RECOVERY.*3GEDoeCA4paXTaDF.*Active V1/);
  assert.match(cutover, /HENVALT_DELIVERY.*CvVyybGJZSnklxiZ.*Active V1/);
  assert.match(cutover, /manual-trigger one-off test-email branch/);
  assert.match(cutover, /do not establish instance-wide execution retention or sensitive-data redaction/i);
  assert.match(cutover, /No active n8n version was changed/);
});

test("exact-store lineage foundation never guesses or backfills legacy connection identity", () => {
  assert.match(lineageFoundation, /ADD COLUMN IF NOT EXISTS shopify_connection_id uuid/);
  assert.match(lineageFoundation, /NOT VALID/);
  assert.match(lineageFoundation, /NULL means historical or unresolved/);
  assert.doesNotMatch(lineageFoundation, /UPDATE henvalt\\.(customers|sessions|session_aliases|checkouts|canonical_events)\\s+SET\\s+shopify_connection_id/i);
});

test("production cutover contract preserves explicit stage gates and fail-closed rollback", () => {
  assert.match(cutover, /\*\*Decision: HOLD\.\*\*/);
  assert.match(cutover, /production-like clone/i);
  assert.match(cutover, /no V1\/V2 dual ingress/i);
  assert.match(cutover, /manual one-off sender branch/i);
  assert.match(cutover, /AMBIGUOUS provider submission[\s\S]*never blindly retried/i);
  assert.match(cutover, /Before schema change[\s\S]*After additive schema change/i);
  assert.match(cutover, /exact-store paid-order attribution/i);
  assert.match(cutover, /No stage below is implied by approval of another stage/i);
  assert.match(cutover, /HOLD \/ NOT LAUNCH-READY/);
});
