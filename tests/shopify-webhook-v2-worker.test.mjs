import test from "node:test";
import assert from "node:assert/strict";
import worker from "../cloudflare/worker.js";
const enc=new TextEncoder();
function req(path,body){return new Request("https://ingress.example"+path,{method:"POST",headers:{"x-shopify-shop-domain":"store-a.myshopify.com","x-shopify-topic":"orders/create","x-shopify-hmac-sha256":"A".repeat(43)+"=","x-shopify-webhook-id":"delivery-123"},body});}
test("V2 Worker forwards untouched bytes through protected Edge ingress without app/service-role secrets",async()=>{
 const body=enc.encode('{"id":123}');
 const original=globalThis.fetch;let captured;
 globalThis.fetch=async(url,init)=>{captured={url,init};return Response.json({accepted:true,duplicate:false,status:"RECEIVED"});};
 try{
  const res=await worker.fetch(req("/shopify/webhooks/"+"a".repeat(64),body),{SUPABASE_WEBHOOK_INGRESS_URL:"https://example.supabase.co/functions/v1/henvalt-shopify-webhook-ingress",HENVALT_INGRESS_AUTH_TOKEN:"internal-token"});
  assert.equal(res.status,200);assert.equal(captured.init.headers.get("authorization"),"Bearer internal-token");
  assert.equal(captured.init.headers.get("x-henvalt-route-token"),"a".repeat(64));assert.deepEqual(new Uint8Array(captured.init.body),body);
  assert.equal(captured.init.headers.get("apikey"),null);
 }finally{globalThis.fetch=original;}
});
test("V2 Worker fails closed if Edge ingress does not confirm durable acceptance",async()=>{
 const original=globalThis.fetch;globalThis.fetch=async()=>Response.json({error:"hmac_invalid"},{status:401});
 try{const res=await worker.fetch(req("/shopify/webhooks/"+"b".repeat(64),enc.encode("{}")),{SUPABASE_WEBHOOK_INGRESS_URL:"https://example.supabase.co/functions/v1/henvalt-shopify-webhook-ingress",HENVALT_INGRESS_AUTH_TOKEN:"internal-token"});assert.equal(res.status,401);}
 finally{globalThis.fetch=original;}
});
test("legacy webhook route remains separately wired to the existing verifier and n8n",async()=>{
 const body=enc.encode("{}");
 const key=await crypto.subtle.importKey("raw",enc.encode("legacy-secret"),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 const sig=new Uint8Array(await crypto.subtle.sign("HMAC",key,body));let bin="";for(const b of sig)bin+=String.fromCharCode(b);const hmac=btoa(bin);
 const original=globalThis.fetch;let called=false;globalThis.fetch=async()=>{called=true;return Response.json({ok:true});};
 try{const r=req("/shopify/webhooks",body);const headers=new Headers(r.headers);headers.set("x-shopify-hmac-sha256",hmac);const res=await worker.fetch(new Request(r,{headers}),{SHOPIFY_API_SECRET:"legacy-secret",N8N_INGEST_URL:"https://n8n.test"});assert.equal(res.status,200);assert.equal(called,true);}
 finally{globalThis.fetch=original;}
});

test("V2 Worker rejects non-Supabase or non-ingress upstream URLs before network access",async()=>{
 const original=globalThis.fetch;let called=false;globalThis.fetch=async()=>{called=true;return Response.json({accepted:true});};
 try{
  const res=await worker.fetch(req("/shopify/webhooks/"+"c".repeat(64),enc.encode("{}")),{SUPABASE_WEBHOOK_INGRESS_URL:"https://attacker.example/collect",HENVALT_INGRESS_AUTH_TOKEN:"internal-token"});
  assert.equal(res.status,503);assert.equal(called,false);
 }finally{globalThis.fetch=original;}
});
test("V2 Worker enforces the 1 MB limit while streaming before forwarding",async()=>{
 const original=globalThis.fetch;let called=false;globalThis.fetch=async()=>{called=true;return Response.json({accepted:true});};
 try{
  const huge=new Uint8Array(1_000_001);
  const res=await worker.fetch(req("/shopify/webhooks/"+"d".repeat(64),huge),{SUPABASE_WEBHOOK_INGRESS_URL:"https://example.supabase.co/functions/v1/henvalt-shopify-webhook-ingress",HENVALT_INGRESS_AUTH_TOKEN:"internal-token"});
  assert.equal(res.status,413);assert.equal(called,false);
 }finally{globalThis.fetch=original;}
});
