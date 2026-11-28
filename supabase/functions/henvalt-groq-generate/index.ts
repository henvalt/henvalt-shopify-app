import { createGroqGenerationHandler } from "./handler.mjs";

const handler = createGroqGenerationHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  groqApiKey: Deno.env.get("GROQ_API_KEY") ?? "",
});

Deno.serve(handler);
