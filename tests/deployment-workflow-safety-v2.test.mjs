import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const release = readFileSync(".github/workflows/release-henvalt-8.yml", "utf8");
const config = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");
const identity = readFileSync(".github/workflows/shopify-identity-v2-validation.yml", "utf8");
const runbook = readFileSync("docs/deployment-and-release-runbook-2026-11-18.md", "utf8");
const launchMatrix = readFileSync("docs/launch-readiness-matrix-2026-11-19.md", "utf8");
const cutover = readFileSync("docs/production-cutover-preflight-and-rollback-2026-11-19.md", "utf8");

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
  assert.match(identity, /Apply candidate migrations 001 through 047/);
  assert.match(identity, /202611190004_shopify_checkout_candidate_terminal_state_v2\.sql/);
  assert.match(runbook, /candidate migrations 001–047/i);
  assert.match(runbook, /Candidate migrations 001–047: CI fixture only; not production-applied\./);
  assert.match(launchMatrix, /Candidate migrations 001–047 apply in disposable PostgreSQL CI/);
  assert.doesNotMatch(runbook, /migrations 001–046/);
  assert.doesNotMatch(launchMatrix, /migrations 001–046/);
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
