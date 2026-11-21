import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("candidate cross-store ambiguity diagnostics are read-only", () => {
  const sql = readFileSync(
    new URL("../docs/sql/candidate-cross-store-ambiguity-review-only.sql", import.meta.url),
    "utf8",
  );
  const withoutComments = sql.replace(/--[^\n]*/g, "").replace(/'(?:''|[^'])*'/g, "''").trim();
  const statements = withoutComments
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);

  assert.equal(statements.length, 5, "Expected five read-only diagnostics");
  for (const statement of statements) {
    assert.match(statement, /^(WITH\b|SELECT\b)/i);
    assert.doesNotMatch(
      statement,
      /\b(INSERT|UPDATE|DELETE|MERGE|ALTER|CREATE|DROP|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/i,
      "Diagnostics must never mutate production",
    );
  }
  assert.match(sql, /DO NOT APPLY/i);
  assert.match(sql, /active_connections_that_current_join_can_match/);
  assert.match(sql, /metadata->>'shop_domain'/);
});
