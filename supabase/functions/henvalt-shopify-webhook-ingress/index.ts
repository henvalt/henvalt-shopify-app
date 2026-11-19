import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readBoundedBody, RequestBodyError } from "../_shared/request-body-v2.ts";
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
function firstRow(value: unknown): Record<string, unknown> | null {
  if (Array.isArray(value)) return (value[0] && typeof value[0] === "object") ? value[0] as Record<string, unknown> : null;
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}
async function readBoundedJson(response: Response, maxBytes = 32_768): Promise<unknown | null> {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\\d+$/.test(declared) || Number(declared) > maxBytes)) return null;
  const reader = response.body?.getReader();
  if (!reader) return null;
  const chunks: Uint8Array[] = []; let total = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch { /* oversized response remains rejected */ }
        return null;
      }
      chunks.push(part.value);
    }
  } catch { return null; }
  finally { try { reader.releaseLock(); } catch { /* already released */ } }
  try {
    const bytes = new Uint8Array(total); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch { return null; }
}
async function rpc(name: string, body: Record<string, unknown>): Promise<{ ok: boolean; row: Record<string, unknown> | null }> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: SERVICE_ROLE_KEY, authorization: "Bearer " + SERVICE_ROLE_KEY, "content-type": "application/json", accept: "application/json", "accept-profile": "henvalt", "content-profile": "henvalt" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    console.error("Webhook RPC failed", name, response.status);
    return { ok: false, row: null };
  }
  const payload = await readBoundedJson(response);\n  if (payload === null) {\n    console.error("Webhook RPC response rejected", name);\n    return { ok: false, row: null };\n  }\n  return { ok: true, row: firstRow(payload) };
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
  let raw: Uint8Array;
  try { raw = await readBoundedBody(req,1_000_000); }
  catch (error) {
    if (error instanceof RequestBodyError) return json(error.code === "BODY_TOO_LARGE" ? 413 : 400,{error:error.code.toLowerCase()});
    return json(400,{error:"invalid_webhook_body"});
  }
  const encodedBody=base64(raw);

  const accepted=await rpc("accept_shopify_webhook_v2",{
    p_route_token:routeToken,p_hmac_base64:hmac,p_raw_body_base64:encodedBody,p_shop_domain:shop,p_topic:topic,p_delivery_id:deliveryId,p_event_id:eventId,
  });
  if(!accepted.ok) return json(503,{error:"verified_inbox_unavailable"});
  const receipt=accepted.row;
  if(!receipt || typeof receipt.accepted!=="boolean") return json(503,{error:"verified_inbox_invalid_response"});
  if(receipt.accepted!==true){
    const code=typeof receipt.rejection_code==="string"?receipt.rejection_code:"webhook_rejected";
    const status=code==="HMAC_INVALID"||code==="ROUTE_TOKEN_INVALID"?401:code==="SHOP_DOMAIN_MISMATCH"||code==="SHOP_ID_MISMATCH"?403:code==="INVALID_REQUEST"?400:503;
    return json(status,{error:code.toLowerCase()});
  }

  // Project only after the verified receipt exists. The RPC compares the exact
  // raw-body digest against that receipt and resolves the same install token.
  // Calling on duplicate retries lets a transient prior projection recover.
  if(topic==="checkouts/create" || topic==="checkouts/update"){
    const projected=await rpc("project_verified_shopify_checkout_v2",{
      p_route_token:routeToken,p_delivery_id:deliveryId,p_raw_body_base64:encodedBody,
    });
    if(!projected.ok || !projected.row || projected.row.accepted!==true){
      return json(503,{error:"checkout_projection_unavailable"});
    }
    const jurisdiction=await rpc("project_verified_shopify_checkout_jurisdiction_v2",{
      p_route_token:routeToken,p_delivery_id:deliveryId,p_raw_body_base64:encodedBody,
    });
    if(!jurisdiction.ok || !jurisdiction.row || jurisdiction.row.accepted!==true){
      return json(503,{error:"checkout_jurisdiction_projection_unavailable"});
    }
    return json(200,{
      accepted:true,
      duplicate:receipt.duplicate===true,
      status:receipt.receipt_status,
      checkout_projection:projected.row.status,
      jurisdiction_known:jurisdiction.row.jurisdiction_known===true,
    });
  }

  if(topic==="customers_email_marketing_consent/update"){
    const projected=await rpc("project_verified_shopify_email_consent_v2",{
      p_route_token:routeToken,p_delivery_id:deliveryId,p_raw_body_base64:encodedBody,
    });
    if(!projected.ok || !projected.row || projected.row.accepted!==true){
      return json(503,{error:"consent_projection_unavailable"});
    }
    return json(200,{
      accepted:true,
      duplicate:receipt.duplicate===true,
      status:receipt.receipt_status,
      consent_projection:projected.row.status,
      consent_state:projected.row.consent_state,
    });
  }

  if(["orders/create","orders/updated","orders/paid","orders/cancelled"].includes(topic)){
    const projected=await rpc("project_verified_shopify_order_v2",{
      p_route_token:routeToken,p_delivery_id:deliveryId,p_raw_body_base64:encodedBody,
    });
    if(!projected.ok || !projected.row || projected.row.accepted!==true){
      return json(503,{error:"order_projection_unavailable"});
    }
    return json(200,{
      accepted:true,
      duplicate:receipt.duplicate===true,
      status:receipt.receipt_status,
      order_projection:projected.row.status,
      checkout_match_status:projected.row.checkout_match_status,
    });
  }

  if(topic==="refunds/create"){
    const projected=await rpc("project_verified_shopify_refund_v2",{
      p_route_token:routeToken,p_delivery_id:deliveryId,p_raw_body_base64:encodedBody,
    });
    if(!projected.ok || !projected.row || projected.row.accepted!==true){
      return json(503,{error:"refund_projection_unavailable"});
    }
    return json(200,{
      accepted:true,
      duplicate:receipt.duplicate===true,
      status:receipt.receipt_status,
      refund_projection:projected.row.status,
      refund_adjustment_id:projected.row.refund_adjustment_id,
    });
  }

  return json(200,{accepted:true,duplicate:receipt.duplicate===true,status:receipt.receipt_status});
});
