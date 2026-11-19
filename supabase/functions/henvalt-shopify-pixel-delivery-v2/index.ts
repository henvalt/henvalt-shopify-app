import { mailerSendV2DeliveryReady, renderRecoveryMessageV2 } from "../_shared/recovery-message-v2.mjs";

declare const Deno: {
 env: { get(name: string): string | undefined };
 serve(handler: (request: Request) => Response | Promise<Response>): void;
};

const SUPABASE_URL=Deno.env.get("SUPABASE_URL")??"";
const SERVICE_ROLE_KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const DELIVERY_AUTH_TOKEN=Deno.env.get("HENVALT_PIXEL_DELIVERY_AUTH_TOKEN")??"";
const MAILERSEND_V2_EVENTS_READY=Deno.env.get("HENVALT_V2_MAILERSEND_EVENTS_READY")==="true";
const API_VERSION="2026-10";
const json=(status:number,body:Record<string,unknown>)=>new Response(JSON.stringify(body),{
 status,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store"}
});
function equal(a:string,b:string){const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return false;let d=0;for(let i=0;i<x.length;i++)d|=x[i]^y[i];return d===0;}
function row(v:unknown):Record<string,any>|null{return Array.isArray(v)?(v[0]&&typeof v[0]==="object"?v[0] as Record<string,any>:null):(v&&typeof v==="object"?v as Record<string,any>:null);}
async function parseJsonLimited(request:Request,maxBytes:number):Promise<unknown>{
 const reader=request.body?.getReader();
 if(!reader)throw new Error("EMPTY_BODY");
 const chunks:Uint8Array[]=[];let total=0;
 try{
  while(true){
   const part=await reader.read();
   if(part.done)break;
   total+=part.value.byteLength;
   if(total>maxBytes){try{await reader.cancel();}catch{}throw new Error("BODY_TOO_LARGE");}
   chunks.push(part.value);
  }
 }finally{try{reader.releaseLock();}catch{}}
 const bytes=new Uint8Array(total);let offset=0;
 for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
 return JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(bytes));
}
const uuid=(v:unknown)=>typeof v==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
async function rpc(name:string,body:Record<string,unknown>){
 const r=await fetch(SUPABASE_URL+"/rest/v1/rpc/"+name,{method:"POST",
  headers:{apikey:SERVICE_ROLE_KEY,authorization:"Bearer "+SERVICE_ROLE_KEY,
   "content-type":"application/json","accept-profile":"henvalt","content-profile":"henvalt"},
  body:JSON.stringify(body),signal:AbortSignal.timeout(12000)});
 if(!r.ok)throw new Error("RPC_FAILED");
 return row(await r.json().catch(()=>null));
}
function validEmail(v:unknown):v is string{return typeof v==="string"&&v.length<=320&&/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(v);}
function normalizedState(v:unknown):string{
 const s=typeof v==="string"?v.toUpperCase():"UNKNOWN";
 return ["SUBSCRIBED","NOT_SUBSCRIBED","UNSUBSCRIBED","PENDING","INVALID","REDACTED"].includes(s)?s:"UNKNOWN";
}
async function fingerprint(email:string,secret:string){
 const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 const bytes=new Uint8Array(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(email.trim().toLowerCase())));
 return [...bytes].map(x=>x.toString(16).padStart(2,"0")).join("");
}
async function lookupCustomer(shop:string,token:string,gid:string){
 const response=await fetch("https://"+shop+"/admin/api/"+API_VERSION+"/graphql.json",{
  method:"POST",headers:{"x-shopify-access-token":token,"content-type":"application/json",accept:"application/json"},
  body:JSON.stringify({query:"query HENVALTPixelDeliveryCustomer($id: ID!) { customer(id: $id) { id email emailMarketingConsent { marketingState consentUpdatedAt } defaultAddress { countryCodeV2 provinceCode } } }",variables:{id:gid}}),
  signal:AbortSignal.timeout(15000)
 });
 if(!response.ok)throw new Error("SHOPIFY_LOOKUP_FAILED");
 const payload=await response.json().catch(()=>({}));
 if(payload.errors?.length||payload.data?.customer?.id!==gid)throw new Error("SHOPIFY_LOOKUP_FAILED");
 const customer=payload.data.customer;
 return {
  email:validEmail(customer.email)?customer.email.trim():null,
  state:normalizedState(customer.emailMarketingConsent?.marketingState),
  consentUpdatedAt:typeof customer.emailMarketingConsent?.consentUpdatedAt==="string"?customer.emailMarketingConsent.consentUpdatedAt:null,
  country:typeof customer.defaultAddress?.countryCodeV2==="string"&&/^[A-Z]{2}$/.test(customer.defaultAddress.countryCodeV2)?customer.defaultAddress.countryCodeV2:null,
  region:typeof customer.defaultAddress?.provinceCode==="string"&&/^[A-Za-z0-9-]{1,12}$/.test(customer.defaultAddress.provinceCode.trim())?customer.defaultAddress.provinceCode.trim().toUpperCase():null
 };
}
async function recordFreshEvidence(connectionId:string,customerIdentityId:string,customer:Awaited<ReturnType<typeof lookupCustomer>>){
 const observed=new Date().toISOString();
 const contact=await rpc("record_shopify_customer_contact_evidence_v3",{
  p_connection_id:connectionId,p_customer_identity_id:customerIdentityId,
  p_contact_available:customer.email!==null,p_country_code:customer.country,p_region_code:customer.region,
  p_observed_at:observed,p_lookup_id:crypto.randomUUID()
 });
 if(contact?.accepted!==true)throw new Error("CONTACT_EVIDENCE_REJECTED");
 const consent=await rpc("record_shopify_customer_marketing_consent_lookup_v2",{
  p_connection_id:connectionId,p_customer_identity_id:customerIdentityId,
  p_marketing_state:customer.state,p_consent_updated_at:customer.consentUpdatedAt,
  p_observed_at:observed,p_lookup_id:crypto.randomUUID()
 });
 if(consent?.accepted!==true)throw new Error("CONSENT_EVIDENCE_REJECTED");
 return observed;
}
async function recordAttempt(id:string,status:"SUBMITTED"|"FAILED"|"AMBIGUOUS",messageRef?:string){
 return await rpc("record_shopify_pixel_send_attempt_result_v2",{
  p_send_attempt_id:id,p_status:status,p_provider_message_reference:messageRef??null
 });
}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return json(405,{error:"method_not_allowed"});
 if(!SUPABASE_URL||!SERVICE_ROLE_KEY||!DELIVERY_AUTH_TOKEN)return json(503,{error:"pixel_delivery_not_configured"});
 const bearer=(req.headers.get("authorization")??"").match(/^Bearer\s+(.+)$/i)?.[1]??"";
 if(!bearer||!equal(bearer,DELIVERY_AUTH_TOKEN))return json(401,{error:"unauthorized"});
 if(!MAILERSEND_V2_EVENTS_READY)return json(503,{error:"v2_provider_event_path_not_ready"});
 const declaredLength=Number(req.headers.get("content-length")??"0");
 if(Number.isFinite(declaredLength)&&declaredLength>160000)return json(413,{error:"request_body_too_large"});
 let parsed:unknown;try{parsed=await parseJsonLimited(req,160000);}catch(error){
  if(error instanceof Error&&error.message==="BODY_TOO_LARGE")return json(413,{error:"request_body_too_large"});
  return json(400,{error:"invalid_json"});
 }
 if(!parsed||typeof parsed!=="object"||Array.isArray(parsed))return json(400,{error:"invalid_pixel_delivery_request"});
 const input=parsed as Record<string,unknown>;
 const opportunityId=input.opportunity_id;
 if(Object.keys(input).some(key=>key!=="opportunity_id")||!uuid(opportunityId))
  return json(400,{error:"invalid_pixel_delivery_request"});
 let attemptId="";
 let providerSubmissionStarted=false;
 let providerMessageReference="";
 try{
  const messageContext=await rpc("resolve_shopify_recovery_message_context_v2",{p_work_type:"PIXEL_OPPORTUNITY",p_work_id:opportunityId});
  if(messageContext?.ready!==true)return json(409,{error:"recovery_message_context_not_ready"});
  const ctx=await rpc("resolve_shopify_pixel_delivery_context_v2",{p_opportunity_id:opportunityId});
  if(!ctx||ctx.ready!==true)return json(409,{error:typeof ctx?.code==="string"?ctx.code.toLowerCase():"pixel_delivery_context_not_ready"});
  const shop=String(ctx.shop_domain??""),shopToken=String(ctx.shopify_access_token??"");
  const gid=String(ctx.customer_gid??""),connectionId=String(ctx.shopify_connection_id??"");
  const customerIdentityId=String(ctx.customer_identity_id??""),providerKey=String(ctx.provider_account_key??"");
  const providerToken=String(ctx.mailer_send_api_token??""),fpSecret=String(ctx.recipient_fingerprint_secret??"");
  const senderEmail=String(ctx.from_email??""),senderName=String(ctx.from_name??"");
  const senderId=String(ctx.sender_profile_id??"");
  if(!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop)||shopToken.length<20||
    !gid.startsWith("gid://shopify/Customer/")||!uuid(connectionId)||!uuid(customerIdentityId)||
    !providerKey||providerToken.length<20||fpSecret.length<32||!validEmail(senderEmail)||
    !senderName.trim()||!uuid(senderId))return json(503,{error:"pixel_delivery_context_incomplete"});
  if(!(await mailerSendV2DeliveryReady(providerToken,senderEmail,providerKey,SUPABASE_URL)))
    return json(409,{error:"mailer_send_v2_delivery_preflight_failed"});
  let message;
  try{message=renderRecoveryMessageV2({shopDomain:String(messageContext.shop_domain??""),opportunityType:String(messageContext.opportunity_type??""),brandName:senderName});}
  catch{return json(409,{error:"recovery_message_context_invalid"});}

  // First live Shopify read refreshes PII-free contact and consent evidence before permit issue.
  const first=await lookupCustomer(shop,shopToken,gid);
  if(!first.email)return json(409,{error:"shopify_customer_email_unavailable"});
  await recordFreshEvidence(connectionId,customerIdentityId,first);
  if(first.state!=="SUBSCRIBED"||!first.consentUpdatedAt)return json(409,{error:"current_shopify_marketing_consent_required"});
  const firstFingerprint=await fingerprint(first.email,fpSecret);

  const permit=await rpc("issue_shopify_pixel_delivery_permit_v2",{
   p_opportunity_id:opportunityId,p_provider_account_key:providerKey,
   p_sender_profile_id:senderId,p_recipient_fingerprint_hex:firstFingerprint
  });
  if(permit?.authorized!==true||typeof permit.permit_token!=="string")
   return json(409,{error:typeof permit?.code==="string"?permit.code.toLowerCase():"pixel_permit_not_issued"});
  const consumed=await rpc("consume_shopify_pixel_delivery_permit_v2",{p_permit_token:permit.permit_token});
  if(consumed?.consumed!==true||!uuid(consumed.pixel_send_attempt_id))
   return json(409,{error:typeof consumed?.code==="string"?consumed.code.toLowerCase():"pixel_permit_not_consumed"});
  attemptId=String(consumed.pixel_send_attempt_id);

  // Re-read Shopify after the one-use permit is consumed; never trust cached consent for submission.
  let finalCustomer:Awaited<ReturnType<typeof lookupCustomer>>;
  try{finalCustomer=await lookupCustomer(shop,shopToken,gid);}
  catch{await recordAttempt(attemptId,"FAILED");return json(409,{error:"final_shopify_consent_lookup_failed"});}
  if(!finalCustomer.email||finalCustomer.state!=="SUBSCRIBED"||!finalCustomer.consentUpdatedAt){
   await recordFreshEvidence(connectionId,customerIdentityId,finalCustomer);
   await recordAttempt(attemptId,"FAILED");
   return json(409,{error:"final_shopify_marketing_consent_not_subscribed"});
  }
  const finalFingerprint=await fingerprint(finalCustomer.email,fpSecret);
  if(finalFingerprint!==firstFingerprint){
   await recordFreshEvidence(connectionId,customerIdentityId,finalCustomer);
   await recordAttempt(attemptId,"FAILED");
   return json(409,{error:"shopify_recipient_identity_changed"});
  }
  await recordFreshEvidence(connectionId,customerIdentityId,finalCustomer);
  const finalGate=await rpc("authorize_shopify_pixel_provider_submission_v2",{
   p_send_attempt_id:attemptId,p_recipient_fingerprint_hex:finalFingerprint
  });
  if(finalGate?.authorized!==true){
   await recordAttempt(attemptId,"FAILED");
   return json(409,{error:typeof finalGate?.code==="string"?finalGate.code.toLowerCase():"final_pixel_send_gate_rejected"});
  }

  // Recipient email exists only in this request's memory and provider request body.
  let providerResponse:Response;
  try{
   // From this point the provider may accept the message even if a later
   // response or ledger operation fails. Preserve the cost reservation.
   providerSubmissionStarted=true;
   providerResponse=await fetch("https://api.mailersend.com/v1/email",{
    method:"POST",headers:{authorization:"Bearer "+providerToken,"content-type":"application/json","x-requested-with":"XMLHttpRequest"},
    body:JSON.stringify({from:{email:senderEmail,name:senderName},to:[{email:finalCustomer.email}],
     subject:message.subject,html:message.html,text:message.text}),
    signal:AbortSignal.timeout(20000)
   });
  }catch{
   await recordAttempt(attemptId,"AMBIGUOUS");
   return json(202,{accepted:true,status:"ambiguous_provider_submission",recipient_email_returned:false});
  }
  if(providerResponse.status===202){
   const messageRef=providerResponse.headers.get("x-message-id")??"";
   if(!messageRef){await recordAttempt(attemptId,"AMBIGUOUS");return json(202,{accepted:true,status:"ambiguous_provider_submission",recipient_email_returned:false});}
   providerMessageReference=messageRef;
   const saved=await recordAttempt(attemptId,"SUBMITTED",messageRef);
   if(saved?.recorded!==true){
    await recordAttempt(attemptId,"AMBIGUOUS",messageRef);
    return json(202,{accepted:true,status:"provider_accepted_record_pending",recipient_email_returned:false});
   }
   return json(202,{accepted:true,status:"submitted",recipient_email_returned:false});
  }
  if(providerResponse.status>=500||providerResponse.status===408){
   providerMessageReference=providerResponse.headers.get("x-message-id")??"";
   await recordAttempt(attemptId,"AMBIGUOUS",providerMessageReference||undefined);
   return json(202,{accepted:true,status:"ambiguous_provider_submission",provider_status:providerResponse.status,recipient_email_returned:false});
  }
  await recordAttempt(attemptId,"FAILED");
  return json(502,{accepted:false,error:"provider_submission_rejected",provider_status:providerResponse.status,recipient_email_returned:false});
 }catch{
  // After the provider request begins, a later failure is ambiguous. Never
  // release its reservation or make the attempt eligible for automatic retry.
  if(attemptId){try{await recordAttempt(attemptId,providerSubmissionStarted?"AMBIGUOUS":"FAILED",
    providerSubmissionStarted&&providerMessageReference?providerMessageReference:undefined);}catch{}}
  return json(providerSubmissionStarted?202:503,{
   error:providerSubmissionStarted?"provider_outcome_requires_reconciliation":"pixel_delivery_boundary_unavailable",
   status:providerSubmissionStarted?"ambiguous_provider_submission":"not_submitted",
   recipient_email_returned:false
  });
 }
});
