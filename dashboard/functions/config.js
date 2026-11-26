const PRODUCTION_PROJECT_REF = "ocyplckdojdubyrsxcxa";
const PRODUCTION_CONFIG = {
  enabled: true,
  environment: "production",
  noSend: false,
  supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
  supabaseKey: "sb_publishable_C_Noi9Wp1FfXIQPK67dbuA_mI5bd-1W",
  api: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-merchant-dashboard",
  setup: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-mailersend-setup",
  billingReconciliation: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-billing-reconciliation",
  privacyExport: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-privacy-export",
  shopifyOAuth: "https://ocyplckdojdubyrsxcxa.supabase.co/functions/v1/henvalt-shopify-oauth/auth",
};

const STAGING_HOST_SUFFIX = ".henvalt-dashboard-preview.pages.dev";

export function resolveDashboardConfig(hostname, env = {}) {
  if (hostname === "henvalt-dashboard.pages.dev") return PRODUCTION_CONFIG;
  if (hostname !== "henvalt-dashboard-preview.pages.dev" && !hostname.endsWith(STAGING_HOST_SUFFIX)) return null;

  const projectRef = env.HENVALT_STAGE_SUPABASE_PROJECT_REF || "";
  const supabaseUrl = env.HENVALT_STAGE_SUPABASE_URL || "";
  const supabaseKey = env.HENVALT_STAGE_SUPABASE_PUBLISHABLE_KEY || "";
  if (env.HENVALT_STAGE_NO_SEND !== "true") return null;
  if (!/^[a-z0-9]{20}$/.test(projectRef) || projectRef === PRODUCTION_PROJECT_REF) return null;
  if (supabaseUrl !== `https://${projectRef}.supabase.co`) return null;
  if (!supabaseKey || !supabaseKey.startsWith("sb_publishable_")) return null;

  const functions = `${supabaseUrl}/functions/v1`;
  return {
    enabled: true,
    environment: "staging",
    noSend: true,
    supabaseUrl,
    supabaseKey,
    api: `${functions}/henvalt-merchant-dashboard`,
    setup: null,
    billingReconciliation: `${functions}/henvalt-billing-reconciliation`,
    privacyExport: `${functions}/henvalt-privacy-export`,
    shopifyOAuth: `${functions}/henvalt-shopify-oauth/auth`,
  };
}

export async function onRequest({ request, env }) {
  if (request.method !== "GET") return new Response("method_not_allowed", { status: 405 });
  const hostname = new URL(request.url).hostname;
  const config = resolveDashboardConfig(hostname, env);
  const body = config
    ? `window.HENVALT_CONFIG = Object.freeze(${JSON.stringify(config)});`
    : "window.HENVALT_CONFIG = null;";
  return new Response(body, {
    status: config ? 200 : 503,
    headers: {
      "content-type": "application/javascript; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
