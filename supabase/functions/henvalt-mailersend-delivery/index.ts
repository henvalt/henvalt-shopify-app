import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createDeliveryHandler } from "./handler.mjs";

const handler = createDeliveryHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
});

Deno.serve(handler);
