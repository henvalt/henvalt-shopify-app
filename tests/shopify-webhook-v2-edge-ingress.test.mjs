import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
const src=readFileSync(new URL("../supabase/functions/henvalt-shopify-webhook-ingress/index.ts",import.meta.url),"utf8");
test("Edge ingress authenticates Worker before using service-role key",()=>{
 assert.match(src,/HENVALT_INGRESS_AUTH_TOKEN/);assert.match(src,/constantTimeEqual\(bearer,INGRESS_AUTH_TOKEN\)/);assert.match(src,/SUPABASE_SERVICE_ROLE_KEY/);
});
test("Edge ingress passes validated raw-body metadata to Vault-backed RPC",()=>{
 assert.match(src,/accept_shopify_webhook_v2/);assert.match(src,/p_raw_body_base64:encodedBody/);assert.match(src,/p_hmac_base64:hmac/);assert.match(src,/p_route_token:routeToken/);
 assert.doesNotMatch(src,/console\.(log|error)\([^\n]*(routeToken|raw|hmac|SERVICE_ROLE_KEY)/i);
});

test("Checkout topics require exact-store verified checkout projection before acknowledgement",()=>{
 assert.match(src,/topic==="checkouts\/create" \|\| topic==="checkouts\/update"/);
 assert.match(src,/project_verified_shopify_checkout_v2/);
 assert.match(src,/checkout_projection_unavailable/);
});

test("Order lifecycle topics require exact-store projection before acknowledgement",()=>{
 assert.match(src,/orders\/create/);assert.match(src,/orders\/updated/);assert.match(src,/orders\/paid/);assert.match(src,/orders\/cancelled/);
 assert.match(src,/project_verified_shopify_order_v2/);
 assert.match(src,/order_projection_unavailable/);
});

test("Edge ingress uses the shared streaming byte-bounded reader",()=>{
 assert.match(src,/readBoundedBody\(req,1_000_000\)/);
 assert.match(src,/RequestBodyError/);
 assert.doesNotMatch(src,/await req\\.arrayBuffer\\(\\)/);
});
