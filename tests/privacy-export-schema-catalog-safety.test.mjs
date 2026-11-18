import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(
  new URL("../docs/sql/privacy-export-schema-catalog-read-only.sql", import.meta.url),
  "utf8",
);
const executable = sql.replace(/^\s*--.*$/gm, "");

test("privacy export catalog discovers customer and operational schema metadata", () => {
  for (const token of [
    "pg_catalog.pg_class",
    "pg_catalog.pg_attribute",
    "pg_catalog.pg_constraint",
    "shopify_connection_id",
    "customer_identity_id",
    "checkout_identity_id",
    "shopify_order_id",
    "foreign_keys",
    "convalidated",
    "historical_rows_proven",
  ]) {
    assert.ok(sql.includes(token), \`Missing schema inventory field: \${token}\`);
  }
});

test("privacy export catalog is metadata-only and cannot mutate or read customer rows", () => {
  assert.match(sql, /READ-ONLY ONLY/i);
  assert.match(sql, /'read_only', true/);
  assert.doesNotMatch(executable, /\b(?:INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|CALL|DO|GRANT|REVOKE)\b/i);
  assert.doesNotMatch(executable, /FROM\s+henvalt\./i);
  assert.doesNotMatch(executable, /decrypted_secrets|vault\.decrypted/i);
});
