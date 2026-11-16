import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../docs/sql/exact-store-privacy-lineage-preflight-read-only.sql", import.meta.url), "utf8");
const executable = sql.replace(/^\\s*--.*$/gm, "");

test("exact-store privacy lineage preflight is metadata-only and read-only", () => {
  assert.match(sql, /information_schema\.columns/);
  assert.match(sql, /shopify_connection_id/);
  assert.match(sql, /app_key/);
  assert.match(sql, /count\(DISTINCT tenant_id\)/);
  assert.doesNotMatch(sql, /\b(?:INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|CALL|DO)\b/i);
  assert.doesNotMatch(executable, /payload|email|customer_id|secret/i);
});
