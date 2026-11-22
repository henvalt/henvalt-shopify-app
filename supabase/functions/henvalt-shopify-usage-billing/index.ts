import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createShopifyUsageBillingHandler } from "./handler.mjs";

const handler = createShopifyUsageBillingHandler({
  env: {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL") ?? "",
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    HENVALT_BILLING_WORKER_TOKEN: Deno.env.get("HENVALT_BILLING_WORKER_TOKEN") ?? "",
  },
});

Deno.serve(handler);
