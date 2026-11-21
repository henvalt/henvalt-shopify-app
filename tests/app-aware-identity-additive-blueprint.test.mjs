import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("additive identity migration blueprint preserves rollout safety gates", () => {
  const path = "docs/app-aware-identity-additive-database-migration-blueprint-v2.md";
  const doc = readFileSync(path, "utf8");
  assert.match(doc, /engineering design \/ review-only/i);
  assert.match(doc, /Not applied to Supabase/i);
  assert.match(doc, /app_key \+ shopify_connection_id \+ tenant_id \+ normalized_shop_domain/);
  assert.match(doc, /before any Vault write/i);
  assert.match(doc, /legacy provenance/i);
  assert.match(doc, /shop-redact database function deletes the entire tenant/i);
  assert.match(doc, /Customer identity is store-scoped by default/i);
  assert.match(doc, /Billing decision remains deliberately deferred/i);
  assert.match(doc, /Required two-store regression fixtures/i);
  assert.match(doc, /does not execute DDL or DML/i);
});
