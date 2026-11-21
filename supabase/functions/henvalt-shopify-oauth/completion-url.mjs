const DEFAULT_DASHBOARD_URL = "https://henvalt-dashboard.pages.dev";

export function buildShopifyCompletionUrl(configuredBaseUrl, {
  shop,
  pixelStatus,
  webhooksStatus,
  pixelIssue,
}) {
  let base;
  try {
    base = new URL(configuredBaseUrl || DEFAULT_DASHBOARD_URL);
  } catch {
    base = new URL(DEFAULT_DASHBOARD_URL);
  }
  if (base.protocol !== "https:" || base.username || base.password) {
    base = new URL(DEFAULT_DASHBOARD_URL);
  }

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
