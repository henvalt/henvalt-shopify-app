import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleShopifyWebhookIngress } from "./handler.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const HENVALT_INGRESS_SHARED_SECRET = Deno.env.get("HENVALT_INGRESS_SHARED_SECRET") ?? "";
const HENVALT_STAGE_NO_SEND = Deno.env.get("HENVALT_STAGE_NO_SEND") ?? "";

Deno.serve((request) => handleShopifyWebhookIngress(request, {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  HENVALT_INGRESS_SHARED_SECRET,
  HENVALT_STAGE_NO_SEND,
}));
