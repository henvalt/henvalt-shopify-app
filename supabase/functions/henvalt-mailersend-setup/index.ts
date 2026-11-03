import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const U=Deno.env.get("SUPABASE_URL")??"";
const S=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
const A=Deno.env.get("SUPABASE_ANON_KEY")??"";
const H={"access-control-allow-origin":"*","access-control-allow-headers":"authorization, apikey, content-type","access-control-allow-methods":"POST, OPTIONS","content-type":"application/json","cache-control":"no-store"};
const reply=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers:H});
const validEmail=(v:string)=>v.length<=254&&v.includes("@")&&v.lastIndexOf(".")>v.indexOf("@")+1&&!v.includes(" ");
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:H});
 if(req.method!=="POST")return reply(405,{error:"method_not_allowed"});
 if(!U||!S||!A)return reply(503,{error:"not_configured"});
 let token="";
 try{
  const auth=req.headers.get("authorization")??"";
  const bearer=auth.toLowerCase().startsWith("bearer ")?auth.slice(7).trim():"";
  if(!bearer)return reply(401,{error:"sign_in_required"});
  const check=await fetch(U+"/auth/v1/user",{headers:{apikey:A,authorization:"Bearer "+bearer}});
  if(!check.ok)return reply(401,{error:"invalid_session"});
  const user=await check.json();
  if(typeof user.id!=="string")return reply(401,{error:"invalid_session"});
  const membership=await fetch(U+"/rest/v1/tenant_memberships?select=tenant_id,role&user_id=eq."+encodeURIComponent(user.id)+"&limit=2",{headers:{apikey:S,authorization:"Bearer "+S,"accept-profile":"henvalt"}});
  if(!membership.ok)return reply(500,{error:"membership_lookup_failed"});
  const rows=await membership.json();
  if(!Array.isArray(rows)||rows.length!==1||!rows[0].tenant_id||!["OWNER","ADMIN"].includes(rows[0].role))return reply(403,{error:"owner_or_admin_membership_required"});
  const body=await req.json();
  token=typeof body.api_token==="string"?body.api_token.trim():"";
  const sender=typeof body.sender_email==="string"?body.sender_email.trim().toLowerCase():"";
  const fromName=typeof body.from_name==="string"?body.from_name.trim():"";
  const replyTo=typeof body.reply_to==="string"&&body.reply_to.trim()?body.reply_to.trim().toLowerCase():sender;
  if(token.length<20||token.length>512||!validEmail(sender)||!validEmail(replyTo)||!fromName||fromName.length>120)return reply(400,{error:"invalid_provider_configuration"});
  const domains=await fetch("https://api.mailersend.com/v1/domains?limit=100&verified=true",{headers:{authorization:"Bearer "+token,accept:"application/json"}});
  if(domains.status===401||domains.status===403)return reply(422,{error:"invalid_token_or_domains_read_permission"});
  if(!domains.ok)return reply(502,{error:"mailersend_validation_unavailable"});
  const payload=await domains.json();
  const senderDomain=sender.split("@")[1];
  const match=(payload.data??[]).find((item:any)=>item.is_verified===true&&typeof item.name==="string"&&(senderDomain===item.name.toLowerCase()||senderDomain.endsWith("."+item.name.toLowerCase())));
  if(!match)return reply(422,{error:"sender_domain_not_verified"});
  const saved=await fetch(U+"/rest/v1/rpc/configure_mailersend_provider",{method:"POST",headers:{apikey:S,authorization:"Bearer "+S,"content-type":"application/json","content-profile":"henvalt","accept-profile":"henvalt"},body:JSON.stringify({p_tenant_id:rows[0].tenant_id,p_api_token:token,p_sender_email:sender,p_from_name:fromName,p_reply_to:replyTo,p_domain_name:match.name})});
  if(!saved.ok)return reply(500,{error:"provider_configuration_failed"});
  const result=await saved.json();
  if(result.configured!==true)return reply(500,{error:"provider_configuration_failed"});
  return reply(200,{configured:true,provider:"mailersend",sender:sender,verified_domain:match.name});
 }catch{return reply(500,{error:"provider_setup_failed"});}
 finally{token="";}
});
