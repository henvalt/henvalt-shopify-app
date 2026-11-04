create or replace function henvalt.deactivate_shopify_connection_on_uninstall(
  p_tenant_id uuid,
  p_shop_domain text,
  p_webhook_event_id uuid,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'henvalt', 'public', 'pg_temp'
as $function$
declare
  v_connection_id uuid;
  v_revoked_pixel_keys integer := 0;
begin
  if p_tenant_id is null or nullif(btrim(p_shop_domain),'') is null then
    raise exception 'Tenant and Shopify shop domain are required';
  end if;

  update henvalt.shopify_connections
     set active = false, updated_at = now()
   where tenant_id = p_tenant_id
     and lower(shop_domain) = lower(p_shop_domain)
   returning id into v_connection_id;

  if v_connection_id is null then
    raise exception 'Shopify connection not found for tenant and shop domain';
  end if;

  update henvalt.pixel_keys
     set active = false,
         revoked_at = coalesce(revoked_at, now())
   where tenant_id = p_tenant_id
     and active = true;
  get diagnostics v_revoked_pixel_keys = row_count;

  update henvalt.billing_accounts
     set status = 'CANCELLED',
         cancelled_at = coalesce(cancelled_at, now()),
         updated_at = now()
   where tenant_id = p_tenant_id
     and status <> 'CANCELLED';

  insert into henvalt.audit_log(
    tenant_id,event_name,entity_type,entity_id,actor_type,actor_reference,payload
  ) values (
    p_tenant_id,'shopify_app_uninstalled','shopify_connection',v_connection_id,
    'shopify_webhook',p_shop_domain,
    jsonb_build_object(
      'webhook_event_id',p_webhook_event_id,
      'correlation_id',p_correlation_id,
      'revoked_pixel_key_count',v_revoked_pixel_keys
    )
  );

  return jsonb_build_object(
    'deactivated',true,
    'tenant_id',p_tenant_id,
    'shop_domain',p_shop_domain,
    'connection_id',v_connection_id,
    'billing_cancelled',true,
    'pixel_keys_revoked',v_revoked_pixel_keys
  );
end;
$function$;
