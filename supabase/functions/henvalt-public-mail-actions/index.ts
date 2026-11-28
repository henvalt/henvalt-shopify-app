import { createPublicMailActionsHandler } from "./handler.mjs";

const handler = createPublicMailActionsHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
});

Deno.serve(handler);
