export function isSafeCompletionDashboardUrl(configuredBaseUrl) {
  if (typeof configuredBaseUrl !== "string" || configuredBaseUrl.trim() === "") return false;
  try {
    const base = new URL(configuredBaseUrl);
    return base.protocol === "https:" &&
      !base.username &&
      !base.password &&
      !base.search &&
      !base.hash;
  } catch {
    return false;
  }
}

export function buildShopifyCompletionUrl(configuredBaseUrl, {
  shop,
  pixelStatus,
  webhooksStatus,
  pixelIssue,
}) {
  if (!isSafeCompletionDashboardUrl(configuredBaseUrl)) return null;
  const base = new URL(configuredBaseUrl);
  const completion = new URL("/settings", base.origin);
  completion.searchParams.set("shopify_status", "connected");
  completion.searchParams.set("shop", shop);
  completion.searchParams.set("pixel_status", pixelStatus === "active" ? "active" : "attention");
  completion.searchParams.set("webhooks_status", webhooksStatus === "verified" ? "verified" : "attention");
  if (typeof pixelIssue === "string" && pixelIssue.length > 0) {
    completion.searchParams.set("pixel_issue", pixelIssue.slice(0, 120));
  }
  return completion.toString();
}
