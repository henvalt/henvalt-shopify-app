do $$
declare
  missing text[];
begin
  select array_agg(expected.index_name order by expected.index_name)
    into missing
  from (values
    ('billing_measurement_credit_offsets_charge_measurement_fk_idx'),
    ('billing_measurement_credit_offsets_credit_measurement_fk_idx'),
    ('delivery_generation_incidents_delivery_request_fk_idx'),
    ('delivery_generation_incidents_intervention_fk_idx'),
    ('delivery_retry_commands_intervention_fk_idx'),
    ('email_usage_reservation_events_reservation_fk_idx')
  ) as expected(index_name)
  left join pg_class i on i.relname = expected.index_name
  left join pg_namespace n on n.oid = i.relnamespace and n.nspname = 'henvalt'
  left join pg_index ix on ix.indexrelid = i.oid
  where n.oid is null or ix.indexrelid is null or not ix.indisvalid;

  if missing is not null then
    raise exception 'Missing or invalid FK coverage indexes: %', missing;
  end if;
end $$;

do $$
declare
  actual text[];
begin
  select array_agg(a.attname order by k.ord)
    into actual
  from pg_class i
  join pg_namespace n on n.oid=i.relnamespace
  join pg_index ix on ix.indexrelid=i.oid
  cross join lateral unnest(ix.indkey) with ordinality as k(attnum,ord)
  join pg_attribute a on a.attrelid=ix.indrelid and a.attnum=k.attnum
  where n.nspname='henvalt'
    and i.relname='billing_measurement_credit_offsets_charge_measurement_fk_idx'
    and k.ord=1;
  if actual is distinct from array['charge_measurement_id'] then
    raise exception 'Charge FK index does not lead with charge_measurement_id: %', actual;
  end if;
end $$;

select 'FK_COVERAGE_INDEX_ACCEPTANCE_PASSED' as result;
