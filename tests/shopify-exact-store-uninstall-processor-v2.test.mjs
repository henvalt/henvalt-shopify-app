import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration=readFileSync("supabase/migrations/202611170009_shopify_exact_store_uninstall_processor_v2.sql","utf8");
const sql=readFileSync("tests/sql/shopify-exact-store-uninstall-processor-v2.test.sql","utf8");

test("uninstall receipt processor binds every mutation to exact connection lineage",()=>{
  assert.match(migration,/sc\.id\s*=\s*NEW\.connection_id[\s\S]*?sc\.tenant_id\s*=\s*NEW\.tenant_id[\s\S]*?sc\.app_key\s*=\s*NEW\.app_key[\s\S]*?sc\.shop_domain\s*=\s*NEW\.shop_domain_header/);
  assert.match(migration,/UPDATE henvalt\.shopify_connections[\s\S]*?WHERE id\s*=\s*NEW\.connection_id[\s\S]*?AND tenant_id\s*=\s*NEW\.tenant_id[\s\S]*?AND app_key\s*=\s*NEW\.app_key[\s\S]*?AND shop_domain\s*=\s*NEW\.shop_domain_header/);
});

test("uninstall cancels only unstarted interventions and preserves attempt history",()=>{
  assert.match(migration,/i\.status\s*=\s*'READY_FOR_AUTHORIZATION'[\s\S]*?NOT EXISTS\s*\([\s\S]*?shopify_recovery_send_attempt_v2/);
  assert.match(migration,/DELETE FROM henvalt\.shopify_delivery_permits_v2[\s\S]*?WHERE shopify_connection_id\s*=\s*NEW\.connection_id\s*AND tenant_id\s*=\s*NEW\.tenant_id/);
  assert.doesNotMatch(migration,/DELETE FROM henvalt\.shopify_(?:recovery_send_attempt_v2|pixel_send_attempts_v2)/);
  assert.doesNotMatch(migration,/UPDATE henvalt\.shopify_(?:recovery_send_attempt_v2|pixel_send_attempts_v2)/);
});

test("uninstall processor is triggered only by app/uninstalled receipt insertion and is not callable directly",()=>{
  assert.match(migration,/AFTER INSERT ON henvalt\.shopify_webhook_deliveries[\s\S]*?WHEN \(NEW\.topic = 'app\/uninstalled'\)/);
  assert.match(migration,/REVOKE ALL ON FUNCTION henvalt\.process_shopify_uninstall_receipt_v2\(\)[\s\S]*?FROM PUBLIC, anon, authenticated, service_role/);
});

test("PostgreSQL contract checks trigger scope, privilege boundary and attempt preservation",()=>{
  assert.match(sql,/pg_get_functiondef/);
  assert.match(sql,/AFTER INSERT/);
  assert.match(sql,/shopify_exact_store_uninstall_after_receipt_v2/);
  assert.match(sql,/must preserve attempt history and in-flight outcomes/);
});
