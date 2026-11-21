import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const migration=readFileSync("supabase/migrations/202611170004_shopify_checkout_jurisdiction_projection_v2.sql","utf8");
const ingress=readFileSync("supabase/functions/henvalt-shopify-webhook-ingress/index.ts","utf8");
test("checkout jurisdiction comes only from verified exact-store checkout receipt",()=>{
 assert.match(migration,/raw_body_sha256/);
 assert.match(migration,/shopify_checkout_token=v_token/);
 assert.match(migration,/shipping_address/);
 assert.match(migration,/billing_address/);
 assert.match(migration,/jurisdiction_country_code=v_country/);
});
test("only ISO country code is persisted; address PII is not",()=>{
 assert.match(migration,/address_fields_stored',false/);
 assert.doesNotMatch(migration,/email|phone|postal_code|address1|first_name|last_name/i);
 assert.match(migration,/v_country !~ '\^\[A-Z\]\{2\}\$'/);
});
test("unknown country stays unknown and must not be inferred",()=>{
 assert.match(migration,/jurisdiction_known',v_country IS NOT NULL/);
 assert.match(ingress,/project_verified_shopify_checkout_jurisdiction_v2/);
});
