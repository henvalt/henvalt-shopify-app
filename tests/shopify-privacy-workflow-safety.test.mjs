import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const workflow = readFileSync(new URL("../.github/workflows/controlled-privacy-hmac-test.yml", import.meta.url), "utf8");

test("privacy HMAC workflow is offline and cannot call production", () => {
  assert.match(workflow, /Offline Shopify privacy HMAC contract tests/);
  assert.match(workflow, /node --test tests\/shopify-privacy-hmac-contract\.test\.mjs/);
  assert.doesNotMatch(workflow, /ocyplckdojdubyrsxcxa\.supabase\.co/i);
  assert.doesNotMatch(workflow, /SHOPIFY_API_SECRET/);
  assert.doesNotMatch(workflow, /secrets\./);
  assert.doesNotMatch(workflow, /fetch\s*\(/i);
  assert.doesNotMatch(workflow, /curl\s+/i);
});
