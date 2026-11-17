import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const contract=readFileSync("docs/v2-recipient-resolution-and-delivery-authorization-contract.md","utf8");
const legacy=readFileSync("supabase/functions/henvalt-mailersend-delivery/index.ts","utf8");
const config=readFileSync("shopify.app.toml","utf8");
test("V2 contract explicitly blocks unsafe legacy tenant-scoped provider adapter",()=>{
 assert.match(legacy,/const recipient = body\.to/);
 assert.match(legacy,/get_mailersend_token_for_delivery/);
 assert.match(legacy,/authorize_delivery_request/);
 assert.match(contract,/Do not send V2 work through this endpoint/);
});
test("email recipient stays inside server-side delivery boundary",()=>{
 assert.match(contract,/never returned to the browser, n8n, logs/);
 assert.match(contract,/opaque opportunity\/intervention\/permit identifiers/);
 assert.match(contract,/single-use authorization RPC/);
});
test("Shopify app config requests customer read scope but production email access is separately gated",()=>{
 assert.match(config,/read_customers/);
 assert.match(contract,/Level 2 protected customer data/);
 assert.match(contract,/redacted or unavailable fields/);
});
test("delivery requires exact-store consent, jurisdiction, suppression, order and entitlement checks",()=>{
 for(const phrase of ["current exact-store consent","jurisdiction country/state","exact-store unsubscribe","no same-store order conversion","provider usage cap","uninstall"]) assert.ok(contract.toLowerCase().includes(phrase.toLowerCase()),phrase);
});
