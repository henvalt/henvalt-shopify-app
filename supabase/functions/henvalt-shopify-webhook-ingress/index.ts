import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const INGRESS_AUTH_TOKEN = Deno.env.get("HENVALT_INGRESS_AUTH_TOKEN") ?? "";
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0; for (let i=0;i<x.length;i++) diff |= x[i] ^ y[i];
  return diff === 0;
}
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i=0;i<bytes.length;i+=0x8000) binary += String.fromCharCode(...bytes.subarray(i,i+0x8000));
  return btoa(binary);
}
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405,{error:"method_not_allowed"});
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !INGRESS_AUTH_TOKEN) return json(503,{error:"ingress_configuration_missing"});
  const bearer = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
  if (!bearer || !constantTimeEqual(bearer,INGRESS_AUTH_TOKEN)) return json(401,{error:"unauthorized"});
  const routeToken=req.headers.get("x-henvalt-route-token") ?? "";
  const shop=req.headers.get("x-shopify-shop-domain") ?? "";
  const topic=req.headers.get("x-shopify-topic") ?? "";
  const hmac=req.headers.get("x-shopify-hmac-sha256") ?? "";
  const deliveryId=req.headers.get("x-shopify-webhook-id") ?? "";
  const eventId=req.headers.get("x-shopify-event-id");
  if (!/^[A-Za-z0-9_-]{40,128}$/.test(routeToken) || !/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      !/^[a-z0-9_./-]{1,128}$/.test(topic) || !/^[A-Za-z0-9+/]{43}=$/.test(hmac) ||
      deliveryId.length<1 || deliveryId.length>255 || (eventId!==null && eventId.length>255)) return json(400,{error:"invalid_webhook_metadata"});
  const raw=new Uint8Array(await req.arrayBuffer());
  if(raw.length===0 || raw.length>1_000_000) return json(413,{error:"invalid_body_size"});
  const response=await fetch(SUPABASE_URL+"/rest/v1/rpc/accept_shopify_webhook_v2",{
    method:"POST",
    headers:{apikey:SERVICE_ROLE_KEY,authorization:"Bearer "+SERVICE_ROLE_KEY,"content-type":"application/json","accept-profile":"henvalt","content-profile":"henvalt"},
    body:JSON.stringify({p_route_token:routeToken,p_hmac_base64:hmac,p_raw_body_base64:base64(raw),p_shop_domain:shop,p_topic:topic,p_delivery_id:deliveryId,p_event_id:eventId}),
  });
  if(!response.ok){console.error("Verified webhook RPC failed",response.status);return json(503,{error:"verified_inbox_unavailable"});}
  const payload=await response.json().catch(()=>null);
  const row=Array.isArray(payload)?payload[0]:payload;
  if(!row || typeof row.accepted!=="boolean") return json(503,{error:"verified_inbox_invalid_response"});
  if(!row.accepted){
    const code=typeof row.rejection_code==="string"?row.rejection_code:"webhook_rejected";
    const status=code==="HMAC_INVALID"||code==="ROUTE_TOKEN_INVALID"?401:code==="SHOP_DOMAIN_MISMATCH"||code==="SHOP_ID_MISMATCH"?403:code==="INVALID_REQUEST"?400:503;
    return json(status,{error:code.toLowerCase()});
  }
  return json(200,{accepted:true,duplicate:row.duplicate===true,status:row.receipt_status});
});
