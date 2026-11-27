const STAGING_INGRESS_HOST = "henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev";
const STAGING_PIXEL_COLLECTOR_HOST = "henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev";
const PRODUCTION_INGRESS_HOST = "henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev";
const PRODUCTION_PIXEL_COLLECTOR_HOST = "henvalt-pixel-collector.chmuhammadrehan18.workers.dev";

export function resolveOAuthInfrastructure({
  ingressBaseUrl,
  pixelCollectorUrl,
  requireExplicitHostBinding = false,
  expectedIngressHost = "",
  expectedPixelCollectorHost = "",
}) {
  try {
    const ingress = new URL(ingressBaseUrl);
    const collector = new URL(pixelCollectorUrl);
    const safe = (url) => url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash;
    if (!safe(ingress) || !["", "/"].includes(ingress.pathname)) return { valid: false };
    if (!safe(collector) || collector.pathname !== "/v1/events") return { valid: false };
    if (requireExplicitHostBinding) {
      const ingressHost = String(expectedIngressHost).trim().toLowerCase();
      const pixelHost = String(expectedPixelCollectorHost).trim().toLowerCase();
      if (ingressHost !== STAGING_INGRESS_HOST ||
          pixelHost !== STAGING_PIXEL_COLLECTOR_HOST ||
          ingressHost === PRODUCTION_INGRESS_HOST ||
          pixelHost === PRODUCTION_PIXEL_COLLECTOR_HOST ||
          ingress.hostname.toLowerCase() !== ingressHost ||
          collector.hostname.toLowerCase() !== pixelHost) return { valid: false };
    }
    return {
      valid: true,
      webhookUri: ingress.origin + "/shopify/webhooks",
      pixelCollectorUrl: collector.origin + collector.pathname,
    };
  } catch {
    return { valid: false };
  }
}

export function isOAuthCallbackBoundToSupabase(supabaseUrl, redirectUri) {
  try {
    const project = new URL(supabaseUrl);
    const callback = new URL(redirectUri);
    return project.protocol === "https:" &&
      project.pathname === "/" &&
      !project.username && !project.password && !project.search && !project.hash &&
      callback.protocol === "https:" &&
      callback.origin === project.origin &&
      callback.pathname === "/functions/v1/henvalt-shopify-oauth/callback" &&
      !callback.username && !callback.password && !callback.search && !callback.hash;
  } catch {
    return false;
  }
}
