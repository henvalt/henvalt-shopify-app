-- Customer privacy operations. This migration defines guarded RPCs only; it does not execute any customer deletion.
-- All RPCs are service-role only and tenant-scoped.

create or replace function henvalt.export_shopify_customer_data(
  p_tenant_id uuid,
  p_shopify_customer_id text
) returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $$
declare
  v_customer_ids uuid[];
  v_email text;
  v_result jsonb;
begin
  if p_tenant_id is null or nullif(trim(p_shopify_customer_id), '') is null then
    raise exception 'tenant_id and Shopify customer id are required';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[]), max(c.email)
    into v_customer_ids, v_email
  from henvalt.customers c
  where c.tenant_id = p_tenant_id
    and c.shopify_customer_id = p_shopify_customer_id;

  if cardinality(v_customer_ids) = 0 then
    return jsonb_build_object('found', false, 'shopify_customer_id', p_shopify_customer_id);
  end if;

  select jsonb_build_object(
    'found', true,
    'customer', coalesce((select jsonb_agg(to_jsonb(c) - 'tenant_id') from henvalt.customers c where c.id = any(v_customer_ids)), '[]'::jsonb),
    'checkouts', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.checkouts x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.orders x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'sessions', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.sessions x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'opportunities', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.opportunities x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'conversations', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.customer_conversations x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'conversation_messages', coalesce((
      select jsonb_agg(to_jsonb(cm) - 'tenant_id')
      from henvalt.conversation_messages cm
      join henvalt.customer_conversations cc on cc.id=cm.conversation_id
      where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
    ), '[]'::jsonb),
    'delivery_requests', coalesce((
      select jsonb_agg(to_jsonb(dr) - 'tenant_id')
      from henvalt.delivery_requests dr
      join henvalt.customer_conversations cc on cc.delivery_request_id=dr.id
      where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
    ), '[]'::jsonb),
    'email_suppressions', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.email_suppressions x where x.tenant_id=p_tenant_id and (x.customer_id=any(v_customer_ids) or (v_email is not null and lower(x.email_normalized)=lower(v_email)))), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.canonical_events x where x.tenant_id=p_tenant_id and (x.customer_reference=p_shopify_customer_id or (v_email is not null and lower(x.email)=lower(v_email)))), '[]'::jsonb),
    'generated_at', now()
  ) into v_result;

  return v_result;
end;
$$;

create or replace function henvalt.redact_shopify_customer_data(
  p_tenant_id uuid,
  p_shopify_customer_id text,
  p_customer_email text default null
) returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $$
declare
  v_customer_ids uuid[];
  v_email text := nullif(lower(trim(p_customer_email)), '');
  v_deleted_customers integer := 0;
  v_deleted_events integer := 0;
  v_deleted_messages integer := 0;
  v_updated_checkouts integer := 0;
  v_updated_orders integer := 0;
  v_updated_sessions integer := 0;
begin
  if p_tenant_id is null or nullif(trim(p_shopify_customer_id), '') is null then
    raise exception 'tenant_id and Shopify customer id are required';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[]), coalesce(max(lower(c.email)), v_email)
    into v_customer_ids, v_email
  from henvalt.customers c
  where c.tenant_id = p_tenant_id
    and c.shopify_customer_id = p_shopify_customer_id;

  -- Never broaden deletion beyond this exact tenant and Shopify customer identifier.
  if cardinality(v_customer_ids) = 0 and v_email is null then
    return jsonb_build_object('matched', false, 'reason', 'customer_not_found');
  end if;

  delete from henvalt.canonical_events e
  where e.tenant_id = p_tenant_id
    and (e.customer_reference = p_shopify_customer_id
      or (v_email is not null and lower(e.email) = v_email));
  get diagnostics v_deleted_events = row_count;

  delete from henvalt.messages m
  where m.tenant_id = p_tenant_id
    and v_email is not null
    and lower(m.recipient) = v_email;
  get diagnostics v_deleted_messages = row_count;

  update henvalt.checkouts x
  set customer_id = null, email = null, checkout_token = null, session_reference = null, metadata = '{}'::jsonb,
      updated_at = now()
  where x.tenant_id = p_tenant_id
    and (x.customer_id = any(v_customer_ids) or (v_email is not null and lower(x.email) = v_email));
  get diagnostics v_updated_checkouts = row_count;

  update henvalt.orders x
  set customer_id = null, session_reference = null, tracking_token = null, metadata = '{}'::jsonb,
      updated_at = now()
  where x.tenant_id = p_tenant_id and x.customer_id = any(v_customer_ids);
  get diagnostics v_updated_orders = row_count;

  update henvalt.sessions x
  set customer_id = null, metadata = '{}'::jsonb
  where x.tenant_id = p_tenant_id and x.customer_id = any(v_customer_ids);
  get diagnostics v_updated_sessions = row_count;

  if v_email is not null then
    update henvalt.delivery_requests
    set recipient_reference = '[redacted]', tracking_token = null
    where tenant_id = p_tenant_id and lower(recipient_reference) = v_email;

    update henvalt.conversation_messages x
    set sender_email = '[redacted]', recipient_email = '[redacted]',
        subject = null, body_text = null, body_html = null, headers = '{}'::jsonb,
        attachments = '[]'::jsonb, ai_draft = null
    where x.tenant_id = p_tenant_id
      and (lower(x.sender_email) = v_email or lower(x.recipient_email) = v_email);

    update henvalt.provider_events x
    set recipient_email = null, payload = '{}'::jsonb, processing_result = '{}'::jsonb
    where x.tenant_id = p_tenant_id and lower(x.recipient_email) = v_email;

    update henvalt.email_suppressions x
    set email_normalized = '[redacted]', customer_id = null
    where x.tenant_id = p_tenant_id and lower(x.email_normalized) = v_email;
  end if;

  -- Remove raw webhook/error/audit payloads that identify this customer.
  update henvalt.webhook_events
  set payload = '{}'::jsonb, metadata = '{}'::jsonb
  where tenant_id = p_tenant_id
    and (payload #>> '{customer,id}' = p_shopify_customer_id
      or payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(coalesce(payload #>> '{customer,email}', payload #>> '{email}', '')) = v_email));

  update henvalt.processing_errors
  set payload = '{}'::jsonb, error_message = 'Customer data redacted'
  where tenant_id = p_tenant_id
    and (payload #>> '{customer,id}' = p_shopify_customer_id
      or payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(coalesce(payload #>> '{customer,email}', payload #>> '{email}', '')) = v_email));

  update henvalt.background_jobs
  set payload = '{}'::jsonb, last_error = null
  where tenant_id = p_tenant_id
    and (payload #>> '{customer,id}' = p_shopify_customer_id
      or payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(coalesce(payload #>> '{customer,email}', payload #>> '{email}', '')) = v_email));

  update henvalt.opportunities
  set metadata = '{}'::jsonb
  where tenant_id = p_tenant_id and customer_id = any(v_customer_ids);

  update henvalt.recovery_interventions
  set recipient_reference = '[redacted]'
  where tenant_id = p_tenant_id and v_email is not null and lower(recipient_reference) = v_email;

  update henvalt.delivery_attempts da
  set provider_response = '{}'::jsonb
  where da.tenant_id = p_tenant_id
    and exists (
      select 1 from henvalt.delivery_requests dr
      where dr.id = da.delivery_request_id
        and dr.tenant_id = p_tenant_id
        and dr.recipient_reference = '[redacted]'
    );

  update henvalt.audit_log
  set payload = '{}'::jsonb, actor_reference = null
  where tenant_id = p_tenant_id
    and (payload #>> '{customer,id}' = p_shopify_customer_id
      or payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(coalesce(payload #>> '{customer,email}', payload #>> '{email}', '')) = v_email));

  -- Deleting the customer cascades conversations, message history and unsubscribe tokens.
  if cardinality(v_customer_ids) > 0 then
    delete from henvalt.customers c where c.tenant_id = p_tenant_id and c.id = any(v_customer_ids);
    get diagnostics v_deleted_customers = row_count;
  end if;

  return jsonb_build_object(
    'matched', true,
    'deleted_customers', v_deleted_customers,
    'deleted_events', v_deleted_events,
    'deleted_messages', v_deleted_messages,
    'anonymized_checkouts', v_updated_checkouts,
    'anonymized_orders', v_updated_orders,
    'anonymized_sessions', v_updated_sessions,
    'completed_at', now()
  );
end;
$$;

revoke all on function henvalt.export_shopify_customer_data(uuid, text) from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_customer_data(uuid, text, text) from public, anon, authenticated;
grant execute on function henvalt.export_shopify_customer_data(uuid, text) to service_role;
grant execute on function henvalt.redact_shopify_customer_data(uuid, text, text) to service_role;

-- Shop redaction removes the tenant and all tenant-scoped records through the
-- schema's ON DELETE CASCADE relationships. The compliance receipt is retained
-- with its personal payload removed before the tenant is deleted.
create or replace function henvalt.redact_shopify_shop_data(
  p_privacy_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = henvalt, pg_temp
as $shop_redact$
declare
  v_request henvalt.shopify_privacy_requests%rowtype;
  v_tenant_id uuid;
begin
  if p_privacy_request_id is null then
    raise exception 'privacy request id is required';
  end if;

  select * into v_request
  from henvalt.shopify_privacy_requests
  where id = p_privacy_request_id
  for update;

  if not found or v_request.topic <> 'shop/redact' then
    raise exception 'shop redaction request not found';
  end if;

  if v_request.status = 'COMPLETED' then
    return jsonb_build_object('completed', true, 'already_processed', true);
  end if;

  v_tenant_id := v_request.tenant_id;
  if v_tenant_id is null then
    update henvalt.shopify_privacy_requests
    set status='COMPLETED', payload='{}'::jsonb, processed_at=coalesce(processed_at, now()), last_error=null
    where id=p_privacy_request_id;
    return jsonb_build_object('completed', true, 'tenant_found', false);
  end if;

  -- Detach and sanitize the receipt first; it must survive tenant deletion.
  update henvalt.shopify_privacy_requests
  set tenant_id=null, payload='{}'::jsonb, status='COMPLETED',
      processed_at=now(), last_error=null
  where id=p_privacy_request_id;

  delete from henvalt.tenants where id=v_tenant_id;

  return jsonb_build_object('completed', true, 'tenant_deleted', found, 'processed_at', now());
end;
$shop_redact$;

revoke all on function henvalt.redact_shopify_shop_data(uuid) from public, anon, authenticated;
grant execute on function henvalt.redact_shopify_shop_data(uuid) to service_role;

