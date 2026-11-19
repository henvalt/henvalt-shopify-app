-- Seeded dashboard V2 read-model integration checks.
-- Runs after migrations 001-058 and the synthetic two-store webhook integration.
-- Uses only synthetic tenant/store rows in disposable PostgreSQL.
\set ON_ERROR_STOP on

DO $dashboard_v2$
DECLARE
  v_store_a uuid;
  v_store_b uuid;
  v_result jsonb;
  v_series jsonb;
  v_metrics jsonb;
  v_from timestamptz := '2026-11-16T00:00:00Z';
  v_to timestamptz := '2026-11-18T00:00:00Z';
BEGIN
  SELECT id INTO v_store_a
  FROM henvalt.shopify_connections
  WHERE shop_domain='store-a.myshopify.com';
  SELECT id INTO v_store_b
  FROM henvalt.shopify_connections
  WHERE shop_domain='store-b.myshopify.com';

  IF v_store_a IS NULL OR v_store_b IS NULL THEN
    RAISE EXCEPTION 'Dashboard V2 test requires both synthetic stores';
  END IF;

  -- Store A is active; Store B is intentionally inactive by the preceding
  -- exact-store pixel lifecycle test. The dashboard must fail closed for B.
  v_result := henvalt.control_plane_dashboard_summary_v2(v_store_a,v_from,v_to);
  IF v_result->>'linked' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Active owner-registered Store A was not linked: %',v_result;
  END IF;

  v_metrics := v_result->'metrics';
  IF (v_metrics->>'opportunities')::bigint<>0
     OR (v_metrics->>'messagesSent')::bigint<>0
     OR (v_metrics->>'recoveredOrders')::bigint<>0
     OR (v_metrics->>'revenueRecovered')::numeric<>0
     OR v_metrics->>'currencyMixed' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'Empty dashboard metrics were not zero-safe: %',v_metrics;
  END IF;

  v_series := v_result->'revenueSeries';
  IF jsonb_array_length(v_series)<>3 THEN
    RAISE EXCEPTION 'Dashboard revenue series must include every UTC day in the inclusive range: %',v_series;
  END IF;
  IF v_series->0->>'date'<>'2026-11-16'
     OR v_series->1->>'date'<>'2026-11-17'
     OR v_series->2->>'date'<>'2026-11-18' THEN
    RAISE EXCEPTION 'Dashboard revenue series has incorrect UTC date buckets: %',v_series;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_series) AS days(value)
    WHERE (value->>'amount')::numeric<>0
       OR value->>'currencyMixed' IS DISTINCT FROM 'false'
  ) THEN
    RAISE EXCEPTION 'Empty daily revenue buckets must be zero and single-currency: %',v_series;
  END IF;

  v_result := henvalt.control_plane_dashboard_summary_v2(v_store_b,v_from,v_to);
  IF v_result->>'linked' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'Inactive Store B must not return dashboard metrics: %',v_result;
  END IF;

  BEGIN
    PERFORM henvalt.control_plane_dashboard_summary_v2(v_store_a,v_from,v_to+interval '367 days');
    RAISE EXCEPTION 'Dashboard accepted a date range longer than 366 days';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='Dashboard accepted a date range longer than 366 days' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%invalid_date_range%' THEN RAISE; END IF;
  END;

  IF has_function_privilege('anon','henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz)','EXECUTE')
     OR has_function_privilege('authenticated','henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz)','EXECUTE')
     OR NOT has_function_privilege('service_role','henvalt.control_plane_dashboard_summary_v2(uuid,timestamptz,timestamptz)','EXECUTE') THEN
    RAISE EXCEPTION 'Dashboard summary RPC is not restricted to service_role';
  END IF;
END;
$dashboard_v2$;

SELECT 'shopify_v2_dashboard_read_model_passed' AS result;
