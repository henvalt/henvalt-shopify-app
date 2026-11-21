import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("historical lineage findings document the live webhook and pixel provenance gaps", () => {
  const doc = readFileSync(
    new URL("../docs/exact-store-historical-lineage-preflight-findings.md", import.meta.url),
    "utf8",
  );
  for (const phrase of [
    "4 active Shopify connections across 3 tenants",
    "132 webhook receipts and 166 canonical events",
    "35 canonical events have no webhook parent",
    "henvalt.ingest_pixel_event",
    "selects only `pk.tenant_id`",
    "shop-domain HTTP header is not part of that body HMAC",
    "Keep unresolved / NULL",
    "zero duplicate groups",
    "No production migration was applied",
  ]) {
    assert.ok(doc.includes(phrase), `Missing verified preflight finding: ${phrase}`);
  }
});

test("read-only preflight SQL emits aggregate diagnostics without mutation", () => {
  const sql = readFileSync(
    new URL("../docs/sql/exact-store-lineage-preflight-read-only.sql", import.meta.url),
    "utf8",
  );
  assert.match(sql, /READ-ONLY ONLY/i);
  assert.match(sql, /exact_store_preflight/i);
  assert.match(sql, /webhook_rows_uniquely_matching_connection/i);
  assert.match(sql, /pixel_canonical_rows_without_webhook_parent/i);
  assert.match(sql, /duplicate_groups/i);
  assert.doesNotMatch(sql, /\b(?:INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|TRUNCATE|GRANT|REVOKE)\b/i);
  assert.doesNotMatch(sql, /decrypted_secrets|vault\.decrypted/i);
});
