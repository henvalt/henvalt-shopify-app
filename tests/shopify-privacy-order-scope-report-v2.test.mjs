import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611170022_shopify_privacy_order_scope_report_v2.sql", import.meta.url), "utf8");

test("privacy order scope report binds every order match to receipt tenant, connection and customer", () => {
  assert.match(migration, /sc\.id = r\.connection_id[\s\S]*sc\.tenant_id = r\.tenant_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.match(migration, /o\.tenant_id = v_receipt\.tenant_id[\s\S]*o\.shopify_connection_id = v_receipt\.connection_id[\s\S]*o\.shopify_order_id = s\.shopify_order_id[\s\S]*o\.customer_identity_id = p_customer_identity_id/);
  assert.match(migration, /'REQUESTED'/);
  assert.match(migration, /'TO_REDACT'/);
  assert.match(migration, /'unmatched_order_ids'/);
  assert.match(migration, /'export_data_complete', false/);
});

test("export and redaction preview include the order scope report but remain non-completing", () => {
  assert.match(migration, /'requested_order_scope', henvalt\.shopify_privacy_order_scope_report_v2\(v_receipt\.id, v_customer\.id\)/);
  assert.match(migration, /'completion_eligible', false/);
  assert.match(migration, /'safe_to_execute', false/);
  assert.match(migration, /'mutations_performed', false/);
  assert.doesNotMatch(migration, /\bDELETE\s+FROM\b|\bUPDATE\s+henvalt\./i);
});
