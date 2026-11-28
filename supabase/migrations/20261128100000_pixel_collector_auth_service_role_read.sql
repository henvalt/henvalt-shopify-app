-- The staging pixel Edge Function reads this single digest row with service_role only.
-- The raw collector secret is held only as a Cloudflare Worker secret binding.
REVOKE ALL ON TABLE henvalt.pixel_collector_auth FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE henvalt.pixel_collector_auth TO service_role;
