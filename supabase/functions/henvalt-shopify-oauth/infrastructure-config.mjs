export function resolveOAuthInfrastructure({ ingressBaseUrl, pixelCollectorUrl }) {
  try {
    const ingress = new URL(ingressBaseUrl);
    const collector = new URL(pixelCollectorUrl);
    const safe = (url) => url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash;
    if (!safe(ingress) || !["", "/"].includes(ingress.pathname)) return { valid: false };
    if (!safe(collector) || collector.pathname !== "/v1/events") return { valid: false };
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
