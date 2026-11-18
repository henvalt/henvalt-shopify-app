import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const release = readFileSync(".github/workflows/release-henvalt-8.yml", "utf8");
const config = readFileSync(".github/workflows/shopify-config-validation.yml", "utf8");

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
