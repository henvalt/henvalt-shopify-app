import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("store identity preflight SQL is read-only", () => {
  const sql = readFileSync(
    new URL("../docs/sql/store-identity-preflight-review-only.sql", import.meta.url),
    "utf8",
  );
  const withoutComments = sql
    .replace(/--[^\n]*/g, "")
    .trim();
  const statements = withoutComments
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);

  assert.ok(statements.length >= 3, "Expected multiple diagnostic queries");
  for (const statement of statements) {
    assert.match(statement, /^(WITH\b|SELECT\b)/i, "Only SELECT/CTE statements are permitted");
    assert.doesNotMatch(
      statement,
      /\b(INSERT|UPDATE|DELETE|MERGE|ALTER|CREATE|DROP|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/i,
      "Preflight must never mutate production",
    );
  }
  assert.match(sql, /DO NOT APPLY as a migration/i);
  assert.match(sql, /MISSING_SHOP_MARKER/);
  assert.match(sql, /TENANT_CONNECTION_CONFLICT/);
});
