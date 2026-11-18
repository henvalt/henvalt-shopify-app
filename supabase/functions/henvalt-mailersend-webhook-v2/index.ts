import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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
  const raw=new Uint8Array(await req.arrayBuffer());
  if(raw.length===0||raw.length>1_000_000)return json(413,{error:"invalid_body_size"});
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
  const payload=JSON.parse(new TextDecoder().decode(raw));
  const eventId=payload&&typeof payload==="object"&&payload.data&&typeof payload.data.id==="string"?payload.data.id:"";
  let pixelReconciled=false;
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
    pixelReconciled=reconciliationRow.pixel_attempt_reconciled===true;
  }
  return json(200,{
    accepted:true,
    status:pixelReconciled?"PROCESSED":typeof row.status==="string"?row.status:"ACCEPTED",
    pixel_attempt_reconciled:pixelReconciled,
    suppression_applied:row.suppression_applied===true,
    recipient_pii_stored:false,
  });
});
