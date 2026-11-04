-- Bound pixel rate-limit storage to one row per key and preserve source event time.
alter table henvalt.pixel_rate_limits drop constraint if exists pixel_rate_limits_pkey;
alter table henvalt.pixel_rate_limits add constraint pixel_rate_limits_pkey primary key (key_digest);

create or replace function henvalt.ingest_pixel_event(
  p_key_digest text,
  p_origin text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'henvalt', 'public'
as $function$
declare
  v_tenant_id uuid;
  v_event_id uuid;
  v_duplicate boolean;
  v_event_type text;
  v_event_source_id text;
  v_client_id text;
  v_checkout_reference text;
  v_bucket timestamptz;
  v_request_count integer;
  v_occurred_at timestamptz;
begin
  if p_key_digest is null or p_key_digest !~ '^[0-9a-f]{64}$'
     or p_origin is null or length(p_origin) > 500 or p_origin not like 'https://%'
     or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 12000 then
    raise exception 'Invalid pixel event request';
  end if;
  v_event_type := p_payload->>'event_type';
  v_event_source_id := p_payload->>'event_id';
  v_client_id := p_payload->>'client_id';
  v_checkout_reference := case when v_event_type = 'checkout_started'
    then nullif(btrim(p_payload->>'checkout_reference'), '') else null end;
  if coalesce(p_payload->>'schema_version', '') <> '1'
     or v_event_type is null
     or v_event_type not in ('page_viewed','product_viewed','product_added_to_cart','checkout_started')
     or v_event_source_id is null or length(v_event_source_id) < 1 or length(v_event_source_id) > 160
     or v_client_id is null or length(v_client_id) < 1 or length(v_client_id) > 160
     or (v_checkout_reference is not null and length(v_checkout_reference) > 300) then
    raise exception 'Pixel event failed validation';
  end if;
  begin
    v_occurred_at := coalesce(nullif(p_payload->>'occurred_at', '')::timestamptz, now());
  exception when others then
    v_occurred_at := now();
  end;
  if v_occurred_at > now() + interval '5 minutes'
     or v_occurred_at < now() - interval '90 days' then v_occurred_at := now(); end if;
  select pk.tenant_id into v_tenant_id
  from henvalt.pixel_keys pk join henvalt.tenants t on t.id = pk.tenant_id
  where pk.key_digest = p_key_digest and pk.active = true and pk.revoked_at is null
    and p_origin = any(pk.allowed_origins) and t.status = 'ACTIVE' limit 1;
  if v_tenant_id is null then raise exception 'Pixel key or origin is not authorized'; end if;
  v_bucket := date_trunc('minute', now());
  insert into henvalt.pixel_rate_limits (key_digest, bucket_start, request_count)
  values (p_key_digest, v_bucket, 1)
  on conflict (key_digest) do update set
    request_count = case when henvalt.pixel_rate_limits.bucket_start = excluded.bucket_start
      then henvalt.pixel_rate_limits.request_count + 1 else 1 end,
    bucket_start = excluded.bucket_start
  returning request_count into v_request_count;
  if v_request_count > 120 then
    return jsonb_build_object('accepted', false, 'error', 'rate_limited');
  end if;
  select ue.event_id, ue.is_duplicate into v_event_id, v_duplicate
  from henvalt.upsert_canonical_event(
    v_tenant_id, null, upper(v_event_type), 'OTHER'::henvalt.event_class,
    'SHOPIFY_WEB_PIXEL', v_event_source_id, null, null, v_client_id, v_client_id,
    v_occurred_at, null, null, p_payload - 'public_key',
    jsonb_build_object('collector_version', 1, 'consent_context', 'shopify_pixel_customer_privacy'),
    'shopify-pixel:' || v_event_source_id, null
  ) ue;
  perform henvalt.resolve_identity(v_event_id);
  if v_checkout_reference is not null and length(v_checkout_reference) > 0 then
    perform henvalt.bind_session_alias(v_tenant_id, v_checkout_reference, v_client_id);
  end if;
  return jsonb_build_object('accepted', true, 'duplicate', coalesce(v_duplicate, false), 'event_id', v_event_id);
end;
$function$;
revoke all on function henvalt.ingest_pixel_event(text, text, jsonb) from public;
grant execute on function henvalt.ingest_pixel_event(text, text, jsonb) to service_role;