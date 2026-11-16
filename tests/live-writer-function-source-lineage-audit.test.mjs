import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const audit = readFileSync(
  new URL("../docs/live-writer-function-source-lineage-audit.md", import.meta.url),
  "utf8",
);

test("live writer audit records the unsafe tenant-only writer contracts", () => {
  for (const phrase of [
    "OAuth finalization can reactivate and rewrite a shop-domain connection",
    "upsert_customer",
    "upsert_checkout",
    "upsert_canonical_event",
    "resolve_identity",
    "project_order_from_event",
    "has no connection ID argument",
    "must not fall back to tenant-wide matching",
    "before any Vault write or connection reactivation",
  ]) {
    assert.ok(audit.includes(phrase), `writer audit missing: ${phrase}`);
  }
});

test("writer audit preserves the production safety boundary and regression cases", () => {
  for (const phrase of [
    "Same Shopify customer ID in two stores",
    "Canonical event connection must equal its webhook receipt connection",
    "Order projection uses only customer and checkout rows",
    "did not change production SQL",
    "not approval to apply a migration",
  ]) {
    assert.ok(audit.includes(phrase), `writer safety requirement missing: ${phrase}`);
  }
});
