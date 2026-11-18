import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { readBoundedBody, RequestBodyError } from "../_shared/request-body-v2.ts";

const SUPABASE_URL=Deno.env.get("SUPABASE_URL")??"";
const SERVICE_ROLE_KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const json=(status:number,body:Record<string,unknown>)=>new Response(JSON.stringify(body),{
  status,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store"},
});
function base64(bytes:Uint8Array):string{
  let binary="";
  for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
  return btoa(binary);
}
Deno.serve(async(req:Request)=>{
  if(req.method!=="POST")return json(405,{error:"method_not_allowed"});
  if(!SUPABASE_URL||!SERVICE_ROLE_KEY)return json(503,{error:"provider_ingress_not_configured"});
  const pathParts=new URL(req.url).pathname.split("/").filter(Boolean);
  const providerAccountKey=pathParts[pathParts.length-1]??"";
  const signature=req.headers.get("signature")??"";
  if(!/^[A-Za-z0-9_-]{24,96}$/.test(providerAccountKey)||!/^[0-9a-fA-F]{64}$/.test(signature)){
    return json(400,{error:"invalid_provider_webhook_metadata"});
  }
  if(!/^application\\/json(?:\\s*;|\\s*$)/i.test(req.headers.get("content-type")??""))return json(415,{error:"application_json_required"});
  let raw:Uint8Array;
  try{raw=await readBoundedBody(req,1_000_000);}catch(error){
    const code=error instanceof RequestBodyError?error.code:"INVALID_BODY";
    return json(code==="BODY_TOO_LARGE"?413:400,{error:code==="BODY_TOO_LARGE"?"request_body_too_large":"invalid_body"});
  }
  const response=await fetch(SUPABASE_URL+"/rest/v1/rpc/ingest_mailersend_webhook_v2",{
    method:"POST",
    headers:{
      apikey:SERVICE_ROLE_KEY,authorization:"Bearer "+SERVICE_ROLE_KEY,
      "content-type":"application/json",accept:"application/json",
      "accept-profile":"henvalt","content-profile":"henvalt",
    },
    body:JSON.stringify({
      p_provider_account_key:providerAccountKey,
      p_signature_hex:signature,
      p_raw_body_base64:base64(raw),
    }),
  });
  if(!response.ok){
    console.error("MailerSend webhook inbox unavailable",response.status);
    return json(503,{error:"provider_event_inbox_unavailable"});
  }
  const result=await response.json().catch(()=>null);
  const row=Array.isArray(result)?result[0]:result;
  if(!row||typeof row!=="object"||typeof row.accepted!=="boolean")return json(503,{error:"provider_event_inbox_invalid_response"});
  if(row.accepted!==true){
    const code=typeof row.code==="string"?row.code:"provider_event_rejected";
    const status=code==="SIGNATURE_INVALID"?401:code==="PROVIDER_ACCOUNT_INACTIVE"?403:code==="INVALID_REQUEST"||code==="INVALID_BODY"?400:503;
    return json(status,{error:code.toLowerCase()});
  }
  // The signed inbox may initially be UNMATCHED when the send was a pixel attempt.
  // Reconcile only from this verified event row; never trust a caller-supplied message ID.
  let payload:unknown;
  try{payload=JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(raw));}catch{return json(400,{error:"invalid_provider_event_body"});}
  const event=payload&&typeof payload==="object"&&!Array.isArray(payload)?payload as Record<string,unknown>:null;
  const eventData=event?.data&&typeof event.data==="object"&&!Array.isArray(event.data)?event.data as Record<string,unknown>:null;
  const rawEventId=eventData?.id;
  const eventId=typeof rawEventId==="string"?rawEventId:
    typeof rawEventId==="number"&&Number.isSafeInteger(rawEventId)?String(rawEventId):"";
  let pixelReconciled=false;
  let pixelSuppressionApplied=false;
  if(eventId){
    const reconciliation=await fetch(SUPABASE_URL+"/rest/v1/rpc/reconcile_mailersend_pixel_provider_event_v2",{
      method:"POST",
      headers:{apikey:SERVICE_ROLE_KEY,authorization:"Bearer "+SERVICE_ROLE_KEY,
        "content-type":"application/json",accept:"application/json",
        "accept-profile":"henvalt","content-profile":"henvalt"},
      body:JSON.stringify({p_provider_account_key:providerAccountKey,p_provider_event_id:eventId}),
    });
    if(!reconciliation.ok){
      console.error("MailerSend pixel reconciliation unavailable",reconciliation.status);
      return json(503,{error:"pixel_provider_reconciliation_unavailable"});
    }
    const reconciliationResult=await reconciliation.json().catch(()=>null);
    const reconciliationRow=Array.isArray(reconciliationResult)?reconciliationResult[0]:reconciliationResult;
    if(!reconciliationRow||typeof reconciliationRow.accepted!=="boolean"||reconciliationRow.accepted!==true){
      console.error("MailerSend pixel reconciliation rejected");
      return json(503,{error:"pixel_provider_reconciliation_rejected"});
    }
    if(reconciliationRow.status==="UNMATCHED"){
      // Preserve provider retry semantics while a send response/message reference is still being persisted.
      return json(503,{error:"pixel_provider_event_waiting_for_attempt_correlation"});
    }
    pixelReconciled=reconciliationRow.pixel_attempt_reconciled===true;
    pixelSuppressionApplied=reconciliationRow.suppression_applied===true;
  }
  return json(200,{
    accepted:true,
    status:pixelReconciled?"PROCESSED":typeof row.status==="string"?row.status:"ACCEPTED",
    pixel_attempt_reconciled:pixelReconciled,
    suppression_applied:row.suppression_applied===true||pixelSuppressionApplied,
    recipient_pii_stored:false,
  });
});
