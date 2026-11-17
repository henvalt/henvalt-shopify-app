import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170017_shopify_customer_redaction_fk_inventory_v2.sql", import.meta.url), "utf8");

test("FK inventory recursively follows references from exact-store customer identity", () => {
  assert.match(migration, /WITH RECURSIVE descendants/);
  assert.match(migration, /fk\.confrelid = d\.relid/);
  assert.match(migration, /NOT fk\.conrelid = ANY\(d\.path\)/);
  assert.match(migration, /depth < 12/);
  assert.match(migration, /referencing_columns/);
  assert.match(migration, /referenced_columns/);
  assert.match(migration, /depth_from_customer_identity/);
});

test("FK inventory reports deletion semantics without touching customer rows", () => {
  for (const action of ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]) {
    assert.ok(migration.includes("'" + action + "'"));
  }
  assert.match(migration, /'read_only', true/);
  assert.match(migration, /'dependency_count'/);
  assert.doesNotMatch(migration, /\bDELETE\s+FROM\b|\bUPDATE\s+henvalt\./i);
});

test("FK inventory is service-role-only", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.shopify_customer_redaction_fk_dependency_map_v2\(\)[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.shopify_customer_redaction_fk_dependency_map_v2\(\)\s+TO service_role/);
});
