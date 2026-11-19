-- Register a durable recurring purge for expired customer-data export bundles.
-- Enable Supabase Cron (pg_cron) in the Dashboard before applying this migration.
-- cron.schedule with a stable job name is idempotent/upsert-safe on Supabase.
do $$
begin
  if to_regnamespace('cron') is null
     or to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception
      'Supabase Cron is not enabled. Enable pg_cron in Dashboard > Integrations > Cron, then re-apply this migration.';
  end if;
  if to_regprocedure('henvalt.purge_expired_shopify_privacy_exports()') is null then
    raise exception
      'Privacy export purge function is missing. Apply migration 202611140004 first.';
  end if;
end;
$$;

select cron.schedule(
  'henvalt-privacy-export-expiry-purge',
  '*/15 * * * *',
  'select henvalt.purge_expired_shopify_privacy_exports();'
);
