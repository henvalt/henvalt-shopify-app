DO $$
BEGIN
  IF has_function_privilege('anon', 'henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.control_plane_dashboard_summary(text,timestamptz,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'dashboard summary RPC grant boundary failed';
  END IF;
  IF has_function_privilege('anon', 'henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'henvalt.control_plane_revenue_series(text,timestamptz,timestamptz,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'revenue series RPC grant boundary failed';
  END IF;
END $$;
