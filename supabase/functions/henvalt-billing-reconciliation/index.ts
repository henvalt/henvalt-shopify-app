import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createBillingReconciliationHandler } from "./handler.mjs";

const handler = createBillingReconciliationHandler({
  env: {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL") ?? "",
    SUPABASE_ANON_KEY: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  },
});

Deno.serve(handler);
