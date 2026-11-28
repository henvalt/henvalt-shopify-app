import { createRecoveryExecutorHandler } from "./handler.mjs";

const handler = createRecoveryExecutorHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  groqApiKey: Deno.env.get("GROQ_API_KEY") ?? "",
  publicActionsBaseUrl: Deno.env.get("HENVALT_PUBLIC_ACTIONS_BASE_URL") ?? "",
});

Deno.serve(handler);
