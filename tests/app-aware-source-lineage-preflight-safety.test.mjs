import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("app-aware source-lineage preflight is SELECT-only and review-only", () => {
  const path = "docs/sql/app-aware-source-lineage-preflight-review-only.sql";
  const sql = readFileSync(path, "utf8");
  assert.match(sql, /STATUS: REVIEW-ONLY \/ READ-ONLY/i);
  assert.match(sql, /DO NOT APPLY AS A MIGRATION/i);

  const withoutComments = sql
    .replace(/--[^\n]*/g, "")
    .trim();
  const statements = withoutComments
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);

  assert.ok(statements.length >= 10, "Expected a substantive catalog/data preflight");
  for (const statement of statements) {
    assert.match(
      statement,
      /^select\b/i,
      `Preflight statement must be SELECT-only; found: ${statement.slice(0, 100)}`,
    );
  }

  assert.match(sql, /No raw shop domains or state hashes/i);
  assert.match(sql, /all writer ON CONFLICT clauses reconciled/i);
  assert.match(sql, /isolated two-store fixtures/i);
});
