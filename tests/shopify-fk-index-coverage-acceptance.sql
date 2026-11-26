do $$
declare
  missing text[];
begin
  with expected(index_name, table_name, column_name) as (
    values
      ('billing_measurement_credit_offsets_charge_measurement_fk_idx','billing_measurement_credit_offsets','charge_measurement_id'),
      ('billing_measurement_credit_offsets_credit_measurement_fk_idx','billing_measurement_credit_offsets','credit_measurement_id'),
      ('delivery_generation_incidents_delivery_request_fk_idx','delivery_generation_incidents','delivery_request_id'),
      ('delivery_generation_incidents_intervention_fk_idx','delivery_generation_incidents','intervention_id'),
      ('delivery_retry_commands_intervention_fk_idx','delivery_retry_commands','intervention_id'),
      ('email_usage_reservation_events_reservation_fk_idx','email_usage_reservation_events','reservation_id')
  )
  select array_agg(e.index_name order by e.index_name)
    into missing
  from expected e
  left join pg_class i on i.relname=e.index_name
  left join pg_namespace n on n.oid=i.relnamespace and n.nspname='henvalt'
  left join pg_index ix on ix.indexrelid=i.oid
  left join pg_class t on t.oid=ix.indrelid and t.relname=e.table_name
  left join lateral (
    select a.attname
    from unnest(ix.indkey) with ordinality k(attnum,ord)
    join pg_attribute a on a.attrelid=ix.indrelid and a.attnum=k.attnum
    where k.ord=1
  ) first_col on true
  where n.oid is null or ix.indexrelid is null or not ix.indisvalid
     or t.oid is null or first_col.attname is distinct from e.column_name;

  if missing is not null then
    raise exception 'Missing, invalid, or incorrectly-leading FK indexes: %', missing;
  end if;
end $$;

select 'FK_COVERAGE_INDEX_ACCEPTANCE_PASSED' as result;
