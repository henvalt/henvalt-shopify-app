import pixelCollector from "./pixel-collector.js";

const STAGING_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const STAGING_SUPABASE_HOST = `${STAGING_PROJECT_REF}.supabase.co`;

export function stagingPixelCollectorConfigured(env) {
  try {
    const url = new URL(env.SUPABASE_URL);
    return Boolean(env.HENVALT_STAGE_NO_SEND === "true" &&
      url.protocol === "https:" &&
      url.hostname === STAGING_SUPABASE_HOST &&
      url.pathname === "/" &&
      !url.username && !url.password && !url.search && !url.hash &&
      typeof env.SUPABASE_PUBLISHABLE_KEY === "string" &&
      env.SUPABASE_PUBLISHABLE_KEY.startsWith("sb_publishable_") &&
      typeof env.COLLECTOR_SHARED_SECRET === "string" &&
      env.COLLECTOR_SHARED_SECRET.length >= 32);
  } catch {
    return false;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const configured = stagingPixelCollectorConfigured(env);

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json({
        ok: configured,
        service: "henvalt-pixel-collector-staging-no-send",
        no_send: env.HENVALT_STAGE_NO_SEND === "true",
        configured,
        rate_limit: "database_enforced",
      }, { headers: { "cache-control": "no-store" } });
    }

    if (!configured) {
      return Response.json({ error: "staging_pixel_collector_guard_closed" }, {
        status: 503,
        headers: { "cache-control": "no-store" },
      });
    }

    // The tenant-scoped ingest RPC enforces a per-key minute quota. This
    // fallback keeps the shared collector module usable without a separate
    // Cloudflare rate-limit binding in this isolated staging Worker.
    const stagedEnv = {
      ...env,
      RATE_LIMITER: env.RATE_LIMITER ?? { limit: async () => ({ success: true }) },
    };
    return pixelCollector.fetch(request, stagedEnv);
  },
};
