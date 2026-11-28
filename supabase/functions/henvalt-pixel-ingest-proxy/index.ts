import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handlePixelIngestProxy } from "./handler.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const HENVALT_STAGE_NO_SEND = Deno.env.get("HENVALT_STAGE_NO_SEND") ?? "";

Deno.serve((request) => handlePixelIngestProxy(request, {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  HENVALT_STAGE_NO_SEND,
}));
