import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const URL=Deno.env.get("SUPABASE_URL")??"", KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"", AUTH=Deno.env.get("HENVALT_CONTACT_LOOKUP_AUTH_TOKEN")??"";
const reply=(s:number,b:Record<string,unknown>)=>new Response(JSON.stringify(b),{status:s,headers:{"content-type":"application/json","cache-control":"no-store"}});
function equal(a:string,b:string){const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return false;let d=0;for(let i=0;i<x.length;i++)d|=x[i]^y[i];return d===0;}
const uuid=(v:unknown)=>typeof v==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
async function rpc(name:string,body:Record<string,unknown>){const r=await fetch(URL+"/rest/v1/rpc/"+name,{method:"POST",headers:{apikey:KEY,authorization:"Bearer "+KEY,"content-type":"application/json","accept-profile":"henvalt","content-profile":"henvalt"},body:JSON.stringify(body),signal:AbortSignal.timeout(12000)});if(!r.ok)throw new Error("DB_FAILED");const d=await r.json();return Array.isArray(d)?d[0]:d;}
function marketingState(value:unknown):string{
 const state=typeof value==="string"?value.toUpperCase():"UNKNOWN";
 return ["SUBSCRIBED","NOT_SUBSCRIBED","UNSUBSCRIBED","PENDING","INVALID","REDACTED"].includes(state)?state:"UNKNOWN";
}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return reply(405,{error:"method_not_allowed"});
 if(!URL||!KEY||!AUTH)return reply(503,{error:"lookup_not_configured"});
 const bearer=(req.headers.get("authorization")??"").match(/^Bearer\s+(.+)$/i)?.[1]??"";
 if(!bearer||!equal(bearer,AUTH))return reply(401,{error:"unauthorized"});
 let b:any;try{b=await req.json();}catch{return reply(400,{error:"invalid_json"});}
 if(!uuid(b?.shopify_connection_id)||!uuid(b?.customer_identity_id))return reply(400,{error:"exact_store_identity_required"});
 try{
  const c=await rpc("resolve_shopify_customer_contact_lookup_context_v2",{p_connection_id:b.shopify_connection_id,p_customer_identity_id:b.customer_identity_id});
  if(!c||c.ready!==true)return reply(409,{error:String(c?.code??"lookup_not_ready").toLowerCase()});
  const shop=String(c.shop_domain??""),token=String(c.access_token??""),gid=String(c.customer_gid??"");
  if(!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop)||!gid.startsWith("gid://shopify/Customer/")||token.length<20)return reply(503,{error:"trusted_context_invalid"});
  const r=await fetch("https://"+shop+"/admin/api/2026-10/graphql.json",{method:"POST",headers:{"x-shopify-access-token":token,"content-type":"application/json",accept:"application/json"},body:JSON.stringify({query:"query HENVALTContactEvidence($id: ID!) { customer(id: $id) { id email emailMarketingConsent { marketingState consentUpdatedAt } defaultAddress { countryCodeV2 provinceCode } } }",variables:{id:gid}}),signal:AbortSignal.timeout(15000)});
  if(!r.ok)return reply(502,{error:"shopify_lookup_failed"});
  const d:any=await r.json().catch(()=>({}));if(d.errors?.length)return reply(502,{error:"shopify_lookup_failed"});
  const customer=d?.data?.customer;if(!customer||customer.id!==gid)return reply(409,{error:"customer_not_found_in_exact_store"});
  const email=typeof customer.email==="string"?customer.email.trim():"";
  const available=email.length>0&&email.length<=320&&/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email);
  const raw=customer.defaultAddress?.countryCodeV2,country=typeof raw==="string"&&/^[A-Z]{2}$/.test(raw)?raw:null;
  const rawRegion=customer.defaultAddress?.provinceCode,region=typeof rawRegion==="string"&&/^[A-Za-z0-9-]{1,12}$/.test(rawRegion.trim())?rawRegion.trim().toUpperCase():null;
  const observed=new Date().toISOString(),lookupId=crypto.randomUUID();
  const saved=await rpc("record_shopify_customer_contact_evidence_v3",{p_connection_id:b.shopify_connection_id,p_customer_identity_id:b.customer_identity_id,p_contact_available:available,p_country_code:country,p_region_code:region,p_observed_at:observed,p_lookup_id:lookupId});
  if(!saved||saved.accepted!==true)return reply(409,{error:String(saved?.code??"evidence_rejected").toLowerCase()});
  const consent=customer.emailMarketingConsent??{};
  const consentSaved=await rpc("record_shopify_customer_marketing_consent_lookup_v2",{
   p_connection_id:b.shopify_connection_id,p_customer_identity_id:b.customer_identity_id,
   p_marketing_state:marketingState(consent.marketingState),
   p_consent_updated_at:typeof consent.consentUpdatedAt==="string"?consent.consentUpdatedAt:null,
   p_observed_at:observed,p_lookup_id:crypto.randomUUID()
  });
  if(!consentSaved||consentSaved.accepted!==true)return reply(409,{error:String(consentSaved?.code??"consent_evidence_rejected").toLowerCase()});
  return reply(200,{accepted:true,contact_available:available,country_code_available:country!==null,
   region_code_available:region!==null,marketing_consent_state:marketingState(consent.marketingState),
   contact_evidence_id:saved.evidence_id,consent_evidence_id:consentSaved.evidence_id,
   observed_at:observed,send_authorized:false,recipient_email_returned:false});
 }catch{return reply(503,{error:"contact_lookup_unavailable"});}
});
