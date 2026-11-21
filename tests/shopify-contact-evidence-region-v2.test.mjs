import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const edge=readFileSync("supabase/functions/henvalt-shopify-contact-evidence-v2/index.ts","utf8");
const sql=readFileSync("supabase/migrations/202611180031_shopify_contact_jurisdiction_region_v2.sql","utf8");
test("region evidence is a bounded code only, with no address persistence",()=>{
 assert.ok(sql.includes("ADD COLUMN IF NOT EXISTS region_code text"));
 assert.ok(sql.includes("region_code ~ '^[A-Z0-9-]{1,12}$'"));
 assert.ok(sql.includes("'address_fields_stored',false"));
});
test("Admin resolver reads country and province codes from exact matched customer",()=>{
 assert.match(edge,/customer\(id: \$id\)/);
 assert.match(edge,/customer\.id!==gid/);
 assert.ok(edge.includes("countryCodeV2 provinceCode"));
 assert.ok(edge.includes("record_shopify_customer_contact_evidence_v3"));
});
test("email remains transient and neither country nor region grants sending",()=>{
 assert.ok(edge.includes("recipient_email_returned:false"));
 assert.ok(edge.includes("send_authorized:false"));
 assert.ok(edge.includes("region_code_available:region!==null"));
});
test("region RPC preserves exact-store scope and service-only execution",()=>{
 assert.ok(sql.includes("ci.shopify_connection_id=p_connection_id"));
 assert.match(sql,/GRANT EXECUTE ON FUNCTION henvalt\.record_shopify_customer_contact_evidence_v3[\s\S]*TO service_role/);
 assert.ok(sql.includes("LOOKUP_ID_REPLAY_MISMATCH"));
});
