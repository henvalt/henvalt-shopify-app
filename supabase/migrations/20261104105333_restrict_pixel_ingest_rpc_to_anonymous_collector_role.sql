-- The browser collector uses the anon role with a revocable tenant key.
-- Signed-in merchant clients must not invoke this SECURITY DEFINER ingestion RPC.
revoke execute on function public.henvalt_ingest_pixel_event(text, text, jsonb) from authenticated;
grant execute on function public.henvalt_ingest_pixel_event(text, text, jsonb) to anon, service_role;
