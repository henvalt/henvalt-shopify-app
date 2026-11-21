import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611180024_shopify_privacy_completion_evidence_gate_v2.sql", import.meta.url), "utf8");

test("privacy completion revalidates exact receipt, connection, tenant, app and shop binding", () => {
  assert.match(migration, /JOIN henvalt\.shopify_connections sc[\s\S]*sc\.id = r\.connection_id[\s\S]*sc\.tenant_id = r\.tenant_id[\s\S]*sc\.app_key = r\.app_key[\s\S]*sc\.shop_domain = r\.shop_domain/);
  assert.match(migration, /j\.state = 'CLAIMED'[\s\S]*j\.lease_until > pg_catalog\.now\(\)[\s\S]*j\.claim_token_sha256/);
});

test("privacy completion fails closed until durable export or redaction evidence exists", () => {
  assert.match(migration, /COMPLETION_EVIDENCE_PIPELINE_NOT_IMPLEMENTED/);
  assert.match(migration, /SET state = 'REVIEW_REQUIRED'/);
  assert.match(migration, /SET processing_status = 'REVIEW_REQUIRED'/);
  assert.match(migration, /RETURN false/);
  assert.doesNotMatch(migration, /SET state = 'COMPLETED'/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.complete_shopify_privacy_request_v2\(uuid,text,boolean\)[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.complete_shopify_privacy_request_v2\(uuid,text,boolean\)[\s\S]*TO service_role/);
});
