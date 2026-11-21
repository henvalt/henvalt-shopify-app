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
