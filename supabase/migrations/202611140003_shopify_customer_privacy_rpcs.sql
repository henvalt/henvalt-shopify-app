-- Customer privacy operations. This migration defines guarded RPCs only; it does not execute any customer deletion.
-- All RPCs are service-role only and tenant-scoped.

create or replace function henvalt.export_shopify_customer_data(
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
  v_result jsonb;
begin
  if p_tenant_id is null
     or (nullif(trim(p_shopify_customer_id), '') is null and v_email is null) then
    raise exception 'tenant_id and either Shopify customer id or customer email are required';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[]), max(c.email)
    into v_customer_ids, v_email
  from henvalt.customers c
  where c.tenant_id = p_tenant_id
    and (
      (nullif(trim(p_shopify_customer_id), '') is not null and c.shopify_customer_id = p_shopify_customer_id)
      or (v_email is not null and lower(c.email) = v_email)
    );

  if cardinality(v_customer_ids) = 0 then
    return jsonb_build_object('found', false);
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
      where dr.tenant_id=p_tenant_id and (
        (v_email is not null and lower(dr.recipient_reference)=lower(v_email))
        or dr.id in (
          select cc.delivery_request_id from henvalt.customer_conversations cc
          where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
        )
      )
    ), '[]'::jsonb),
    'delivery_attempts', coalesce((
      select jsonb_agg(to_jsonb(da) - 'tenant_id')
      from henvalt.delivery_attempts da
      join henvalt.delivery_requests dr on dr.id=da.delivery_request_id
      where da.tenant_id=p_tenant_id and dr.tenant_id=p_tenant_id and (
        (v_email is not null and lower(dr.recipient_reference)=lower(v_email))
        or dr.id in (
          select cc.delivery_request_id from henvalt.customer_conversations cc
          where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
        )
      )
    ), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.messages x where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient)=lower(v_email)), '[]'::jsonb),
    'provider_events', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.provider_events x where x.tenant_id=p_tenant_id and v_email is not null and lower(x.recipient_email)=lower(v_email)), '[]'::jsonb),
    'recovery_interventions', coalesce((
      select jsonb_agg(to_jsonb(ri) - 'tenant_id')
      from henvalt.recovery_interventions ri
      left join henvalt.opportunities o on o.id=ri.opportunity_id and o.tenant_id=p_tenant_id
      where ri.tenant_id=p_tenant_id and (
        (v_email is not null and lower(ri.recipient_reference)=lower(v_email))
        or o.customer_id=any(v_customer_ids)
      )
    ), '[]'::jsonb),
    'tracking_tokens', coalesce((
      select jsonb_agg(to_jsonb(tt) - 'tenant_id')
      from henvalt.tracking_tokens tt
      join henvalt.recovery_interventions ri on ri.id=tt.intervention_id and ri.tenant_id=p_tenant_id
      left join henvalt.opportunities o on o.id=ri.opportunity_id and o.tenant_id=p_tenant_id
      where tt.tenant_id=p_tenant_id and (
        (v_email is not null and lower(ri.recipient_reference)=lower(v_email))
        or o.customer_id=any(v_customer_ids)
      )
    ), '[]'::jsonb),
    'unsubscribe_tokens', coalesce((select jsonb_agg(to_jsonb(x) - 'tenant_id') from henvalt.unsubscribe_tokens x where x.tenant_id=p_tenant_id and x.customer_id=any(v_customer_ids)), '[]'::jsonb),
    'webhook_events', coalesce((
      select jsonb_agg(to_jsonb(x) - 'tenant_id')
      from henvalt.webhook_events x
      where x.tenant_id=p_tenant_id and (
        x.payload #>> '{customer,id}'=p_shopify_customer_id
        or x.payload #>> '{id}'=p_shopify_customer_id
        or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=lower(v_email))
      )
    ), '[]'::jsonb),
    'processing_errors', coalesce((
      select jsonb_agg(to_jsonb(x) - 'tenant_id')
      from henvalt.processing_errors x
      where x.tenant_id=p_tenant_id and (
        x.entity_id=any(v_customer_ids)
        or x.payload #>> '{customer,id}'=p_shopify_customer_id
        or x.payload #>> '{id}'=p_shopify_customer_id
        or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=lower(v_email))
      )
    ), '[]'::jsonb),
    'background_jobs', coalesce((
      select jsonb_agg(to_jsonb(x) - 'tenant_id')
      from henvalt.background_jobs x
      where x.tenant_id=p_tenant_id and (
        x.payload #>> '{customer,id}'=p_shopify_customer_id
        or x.payload #>> '{id}'=p_shopify_customer_id
        or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=lower(v_email))
      )
    ), '[]'::jsonb),
    'audit_log', coalesce((
      select jsonb_agg(to_jsonb(x) - 'tenant_id')
      from henvalt.audit_log x
      where x.tenant_id=p_tenant_id and (
        x.entity_id=any(v_customer_ids)
        or x.payload #>> '{customer,id}'=p_shopify_customer_id
        or x.payload #>> '{id}'=p_shopify_customer_id
        or (v_email is not null and lower(coalesce(x.payload #>> '{customer,email}',x.payload #>> '{email}',''))=lower(v_email))
      )
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
  if p_tenant_id is null
     or (nullif(trim(p_shopify_customer_id), '') is null and v_email is null) then
    raise exception 'tenant_id and either Shopify customer id or customer email are required';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[]), coalesce(max(lower(c.email)), v_email)
    into v_customer_ids, v_email
  from henvalt.customers c
  where c.tenant_id = p_tenant_id
    and (
      (nullif(trim(p_shopify_customer_id), '') is not null and c.shopify_customer_id = p_shopify_customer_id)
      or (v_email is not null and lower(c.email) = v_email)
    );

  -- Never broaden deletion beyond this exact tenant and Shopify customer identifier.
  if cardinality(v_customer_ids) = 0 and v_email is null then
    return jsonb_build_object('matched', false, 'reason', 'customer_not_found');
  end if;

  delete from henvalt.canonical_events e
  where e.tenant_id = p_tenant_id
    and (e.customer_reference = p_shopify_customer_id
      or e.payload #>> '{customer,id}' = p_shopify_customer_id
      or e.payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(e.email) = v_email)
      or (v_email is not null and lower(coalesce(e.payload #>> '{customer,email}', e.payload #>> '{email}', '')) = v_email));
  get diagnostics v_deleted_events = row_count;

  delete from henvalt.messages m
  where m.tenant_id = p_tenant_id
    and (
      (v_email is not null and lower(m.recipient) = v_email)
      or m.intervention_id in (
        select ri.id from henvalt.recovery_interventions ri
        left join henvalt.opportunities o on o.id=ri.opportunity_id and o.tenant_id=p_tenant_id
        where ri.tenant_id=p_tenant_id and (
          (v_email is not null and lower(ri.recipient_reference)=v_email)
          or o.customer_id=any(v_customer_ids)
        )
      )
    );
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

  delete from henvalt.tracking_tokens tt
  where tt.tenant_id=p_tenant_id
    and tt.intervention_id in (
      select ri.id
      from henvalt.recovery_interventions ri
      left join henvalt.opportunities o on o.id=ri.opportunity_id and o.tenant_id=p_tenant_id
      where ri.tenant_id=p_tenant_id and (
        (v_email is not null and lower(ri.recipient_reference)=v_email)
        or o.customer_id=any(v_customer_ids)
      )
    );

  update henvalt.delivery_attempts da
  set provider_response = '{}'::jsonb
  where da.tenant_id = p_tenant_id
    and exists (
      select 1 from henvalt.delivery_requests dr
      where dr.id = da.delivery_request_id and dr.tenant_id = p_tenant_id
        and (
          (v_email is not null and lower(dr.recipient_reference) = v_email)
          or dr.id in (
            select cc.delivery_request_id from henvalt.customer_conversations cc
            where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
          )
          or dr.opportunity_id in (
            select o.id from henvalt.opportunities o
            where o.tenant_id=p_tenant_id and o.customer_id=any(v_customer_ids)
          )
        )
    );

  update henvalt.provider_events pe
  set recipient_email = null, payload = '{}'::jsonb, processing_result = '{}'::jsonb
  where pe.tenant_id=p_tenant_id and (
    (v_email is not null and lower(pe.recipient_email)=v_email)
    or pe.delivery_request_id in (
      select dr.id from henvalt.delivery_requests dr
      where dr.tenant_id=p_tenant_id and (
        (v_email is not null and lower(dr.recipient_reference)=v_email)
        or dr.id in (
          select cc.delivery_request_id from henvalt.customer_conversations cc
          where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
        )
        or dr.opportunity_id in (
          select o.id from henvalt.opportunities o
          where o.tenant_id=p_tenant_id and o.customer_id=any(v_customer_ids)
        )
      )
    )
  );

  update henvalt.delivery_requests dr
  set recipient_reference='[redacted]', tracking_token=null
  where dr.tenant_id=p_tenant_id and (
    (v_email is not null and lower(dr.recipient_reference)=v_email)
    or dr.id in (
      select cc.delivery_request_id from henvalt.customer_conversations cc
      where cc.tenant_id=p_tenant_id and cc.customer_id=any(v_customer_ids)
    )
    or dr.opportunity_id in (
      select o.id from henvalt.opportunities o
      where o.tenant_id=p_tenant_id and o.customer_id=any(v_customer_ids)
    )
  );

  update henvalt.recovery_interventions ri
  set recipient_reference='[redacted]'
  where ri.tenant_id=p_tenant_id and (
    (v_email is not null and lower(ri.recipient_reference)=v_email)
    or ri.opportunity_id in (
      select o.id from henvalt.opportunities o
      where o.tenant_id=p_tenant_id and o.customer_id=any(v_customer_ids)
    )
  );

  if v_email is not null then
    update henvalt.conversation_messages x
    set sender_email = '[redacted]', recipient_email = '[redacted]',
        subject = null, body_text = null, body_html = null, headers = '{}'::jsonb,
        attachments = '[]'::jsonb, ai_draft = null
    where x.tenant_id = p_tenant_id
      and (lower(x.sender_email) = v_email or lower(x.recipient_email) = v_email);
  end if;

  -- Suppression rows are removed rather than assigned a shared placeholder email,
  -- which would collide with the active-email unique index.
  delete from henvalt.email_suppressions x
  where x.tenant_id = p_tenant_id
    and (x.customer_id = any(v_customer_ids)
      or (v_email is not null and lower(x.email_normalized) = v_email));

  -- Remove raw webhook/error/audit payloads that identify this customer.
  update henvalt.webhook_events
  set payload = '{}'::jsonb, metadata = '{}'::jsonb
  where tenant_id = p_tenant_id
    and (payload #>> '{customer,id}' = p_shopify_customer_id
      or payload #>> '{id}' = p_shopify_customer_id
      or (v_email is not null and lower(coalesce(payload #>> '{customer,email}', payload #>> '{email}', '')) = v_email));

  update henvalt.processing_errors
  set payload = '{}'::jsonb, error_message = 'Customer data redacted', entity_id = null
  where tenant_id = p_tenant_id
    and (entity_id = any(v_customer_ids)
      or payload #>> '{customer,id}' = p_shopify_customer_id
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

  update henvalt.audit_log
  set payload = '{}'::jsonb, actor_reference = null, entity_id = null
  where tenant_id = p_tenant_id
    and (entity_id = any(v_customer_ids)
      or payload #>> '{customer,id}' = p_shopify_customer_id
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

revoke all on function henvalt.export_shopify_customer_data(uuid, text, text) from public, anon, authenticated;
revoke all on function henvalt.redact_shopify_customer_data(uuid, text, text) from public, anon, authenticated;
grant execute on function henvalt.export_shopify_customer_data(uuid, text, text) to service_role;
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
  set tenant_id=null, customer_id=null, payload='{}'::jsonb, status='COMPLETED',
      processed_at=now(), last_error=null
  where id=p_privacy_request_id;

  delete from henvalt.tenants where id=v_tenant_id;

  return jsonb_build_object('completed', true, 'tenant_deleted', found, 'processed_at', now());
end;
$shop_redact$;

revoke all on function henvalt.redact_shopify_shop_data(uuid) from public, anon, authenticated;
grant execute on function henvalt.redact_shopify_shop_data(uuid) to service_role;

