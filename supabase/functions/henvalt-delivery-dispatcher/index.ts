import { createDeliveryDispatcherHandler } from "./handler.mjs";

const handler = createDeliveryDispatcherHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
});

Deno.serve(handler);
