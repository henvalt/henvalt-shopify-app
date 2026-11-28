-- Dashboard Edge Function verifies the Supabase user and resolves exactly one tenant
-- membership before invoking these SECURITY DEFINER reporting RPCs with service_role.
-- Direct client execution would bypass that membership check because the RPCs accept
-- a shop domain and are SECURITY DEFINER.
REVOKE ALL ON FUNCTION henvalt.control_plane_dashboard_summary(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION henvalt.control_plane_revenue_series(text, timestamptz, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_dashboard_summary(text, timestamptz, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION henvalt.control_plane_revenue_series(text, timestamptz, timestamptz, text) TO service_role;
