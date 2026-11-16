import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("pixel ingestion contract preserves validated key-to-connection lineage", () => {
  const doc = readFileSync(
    new URL("../docs/pixel-ingestion-exact-store-lineage-contract.md", import.meta.url),
    "utf8",
  );
  for (const phrase of [
    "selects only `pk.tenant_id`",
    "shopify_connection_id",
    "connection-qualified idempotency key",
    "store-aware identity resolver",
    "A customer in Store B must never be attached",
    "all 35 historical pixel events remain unresolved",
    "Do not backfill them from the current active pixel key",
    "same database transaction",
    "No DDL, DML, backfill, or function replacement was applied",
  ]) {
    assert.ok(doc.includes(phrase), `Missing pixel lineage contract: ${phrase}`);
  }
});

test("pixel lineage contract includes cross-store idempotency and identity regressions", () => {
  const doc = readFileSync(
    new URL("../docs/pixel-ingestion-exact-store-lineage-contract.md", import.meta.url),
    "utf8",
  );
  assert.match(doc, /Identical event IDs from A and B do not collide/);
  assert.match(doc, /Shared email across A\/B never causes cross-store customer attachment/);
  assert.match(doc, /Checkout lookup for A never returns B's checkout/);
  assert.match(doc, /separate explicit authorization/);
});
