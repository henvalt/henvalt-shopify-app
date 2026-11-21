import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("multi-store migration blueprint is review-only and preserves legacy app identity", () => {
  const plan = readFileSync(
    new URL("../docs/multi-store-identity-migration-blueprint-review-only.md", import.meta.url),
    "utf8",
  );

  for (const required of [
    "app_key + shopify_connection_id",
    "Keep the existing app registration",
    "fail closed",
    "Store-scoped identity and uniqueness",
    "Shop redact: delete/anonymize only store-originated data",
    "Billing principal — decision gate",
    "AMBIGUOUS",
    "No SQL migration is included here",
  ]) {
    assert.ok(plan.includes(required), `Missing migration safety requirement: ${required}`);
  }
  assert.match(plan, /Do not apply, merge or deploy/i);
});
