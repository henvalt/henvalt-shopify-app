create or replace function henvalt.configure_mailersend_provider(
 p_tenant_id uuid,p_api_token text,p_sender_email text,p_from_name text,p_reply_to text,p_domain_name text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, henvalt, vault
as $function$
declare
 v_secret_id uuid;
 v_provider_id uuid;
 v_sender_id uuid;
 v_existing_ref text;
begin
 if p_tenant_id is null or p_api_token is null or length(p_api_token)<20 or length(p_api_token)>512
   or p_sender_email is null or p_from_name is null or p_domain_name is null then
   raise exception 'INVALID_CONFIGURATION' using errcode='22023';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text||':mailersend',0));
 if not exists(select 1 from henvalt.tenants where id=p_tenant_id and status='ACTIVE') then
   raise exception 'TENANT_NOT_ACTIVE' using errcode='22023';
 end if;
 select id,credentials_secret_ref into v_provider_id,v_existing_ref
 from henvalt.provider_configs
 where tenant_id=p_tenant_id and channel='EMAIL' and provider='mailersend'
 order by updated_at desc nulls last,created_at desc limit 1 for update;
 if v_existing_ref is not null
   and v_existing_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and exists(select 1 from vault.secrets where id=v_existing_ref::uuid) then
   v_secret_id:=v_existing_ref::uuid;
   perform vault.update_secret(v_secret_id,p_api_token,'henvalt-mailersend-'||p_tenant_id::text,'HENVALT managed MailerSend API credential');
 else
   v_secret_id:=vault.create_secret(p_api_token,'henvalt-mailersend-'||p_tenant_id::text,'HENVALT managed MailerSend API credential');
 end if;
 if v_provider_id is null then
  insert into henvalt.provider_configs(tenant_id,channel,provider,credentials_secret_ref,configuration,active)
  values(p_tenant_id,'EMAIL','mailersend',v_secret_id::text,
   jsonb_build_object('credential_storage','supabase_vault','credential_validated',true,'verified_domain',p_domain_name,'configured_at',now()),true)
  returning id into v_provider_id;
 else
  update henvalt.provider_configs set credentials_secret_ref=v_secret_id::text,
   configuration=coalesce(configuration,'{}'::jsonb)||jsonb_build_object('credential_storage','supabase_vault','credential_validated',true,'verified_domain',p_domain_name,'configured_at',now()),
   active=true,updated_at=now() where id=v_provider_id;
 end if;
 select id into v_sender_id from henvalt.sending_identities
 where tenant_id=p_tenant_id and channel='EMAIL' and provider='mailersend' and delivery_mode='HENVALT_MANAGED'
 order by updated_at desc nulls last,created_at desc limit 1 for update;
 if v_sender_id is null then
  insert into henvalt.sending_identities(tenant_id,channel,delivery_mode,provider,sender_reference,provider_config_id,active,metadata)
  values(p_tenant_id,'EMAIL','HENVALT_MANAGED','mailersend',p_sender_email,v_provider_id,true,
   jsonb_build_object('from_name',p_from_name,'reply_to',coalesce(p_reply_to,p_sender_email),'verified_domain',p_domain_name,'credential_validated',true))
  returning id into v_sender_id;
 else
  update henvalt.sending_identities set sender_reference=p_sender_email,provider_config_id=v_provider_id,active=true,
   metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('from_name',p_from_name,'reply_to',coalesce(p_reply_to,p_sender_email),'verified_domain',p_domain_name,'credential_validated',true),
   updated_at=now() where id=v_sender_id;
 end if;
 return jsonb_build_object('configured',true,'provider_configured',true,'sender_configured',true);
end;
$function$;
revoke all on function henvalt.configure_mailersend_provider(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function henvalt.configure_mailersend_provider(uuid,text,text,text,text,text) to service_role;
