#!/usr/bin/env node
/**
 * HENVALT Supabase-backed staging preflight.
 * Metadata-only: it never calls APIs, prints secret values, or deploys anything.
 */
const EXPECTED_PROJECT_REF = "xidhtmrfvsgfmyltjuja";
const EXPECTED_INGRESS_HOST = "henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev";
const EXPECTED_PIXEL_HOST = "henvalt-pixel-collector-staging-no-send.chmuhammadrehan18.workers.dev";
const PRODUCTION_PROJECT_REF = "ocyplckdojdubyrsxcxa";
const env = process.env;
const errors = [];
const required = [
  "SUPABASE_URL",
  "SHOPIFY_API_KEY",
  "SHOPIFY_API_SECRET",
  "SHOPIFY_REDIRECT_URI",
  "HENVALT_DASHBOARD_URL",
  "SHOPIFY_WEBHOOK_INGRESS_BASE_URL",
  "SHOPIFY_PIXEL_COLLECTOR_URL",
  "HENVALT_STAGE_SHOPIFY_STORE",
];
for (const key of required) if (!env[key]?.trim()) errors.push(`missing required staging setting: ${key}`);

function parseHttps(name, value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
      errors.push(`${name} must be HTTPS without credentials, query, or fragment`);
    }
    return url;
  } catch {
    errors.push(`${name} is not a valid URL`);
    return null;
  }
}

if (env.SUPABASE_URL) {
  const url = parseHttps("SUPABASE_URL", env.SUPABASE_URL);
  if (url && (url.hostname !== `${EXPECTED_PROJECT_REF}.supabase.co` || url.pathname !== "/")) {
    errors.push("SUPABASE_URL must identify the exact isolated HENVALT staging project");
  }
  if (url?.hostname === `${PRODUCTION_PROJECT_REF}.supabase.co`) errors.push("Supabase project is production");
}
if (env.SHOPIFY_REDIRECT_URI) {
  const callback = parseHttps("SHOPIFY_REDIRECT_URI", env.SHOPIFY_REDIRECT_URI);
  if (callback && (callback.hostname !== `${EXPECTED_PROJECT_REF}.supabase.co` ||
      callback.pathname !== "/functions/v1/henvalt-shopify-oauth/callback" ||
      callback.search || callback.hash)) {
    errors.push("Shopify OAuth callback must use the exact staging Supabase project and callback path");
  }
}
if (env.HENVALT_DASHBOARD_URL) {
  const dashboard = parseHttps("HENVALT_DASHBOARD_URL", env.HENVALT_DASHBOARD_URL);
  if (dashboard && ["henvalt.com", "app.henvalt.com", "henvalt-dashboard.pages.dev"].includes(dashboard.hostname.toLowerCase())) {
    errors.push("OAuth completion dashboard must not use a production host");
  }
}
if (env.SHOPIFY_WEBHOOK_INGRESS_BASE_URL) {
  const ingress = parseHttps("SHOPIFY_WEBHOOK_INGRESS_BASE_URL", env.SHOPIFY_WEBHOOK_INGRESS_BASE_URL);
  if (ingress && (ingress.hostname !== EXPECTED_INGRESS_HOST || !["", "/"].includes(ingress.pathname))) {
    errors.push("OAuth webhook ingress must use the exact dedicated no-send staging Worker origin");
  }
}
if (env.SHOPIFY_PIXEL_COLLECTOR_URL) {
  const pixel = parseHttps("SHOPIFY_PIXEL_COLLECTOR_URL", env.SHOPIFY_PIXEL_COLLECTOR_URL);
  if (pixel && (pixel.hostname !== EXPECTED_PIXEL_HOST || pixel.pathname !== "/v1/events")) {
    errors.push("OAuth pixel collector must use the exact dedicated no-send staging Worker endpoint");
  }
}
if (env.HENVALT_STAGE_INGRESS_HOST !== EXPECTED_INGRESS_HOST) errors.push("HENVALT_STAGE_INGRESS_HOST must exactly match the no-send staging Worker");
if (env.HENVALT_STAGE_PIXEL_COLLECTOR_HOST !== EXPECTED_PIXEL_HOST) errors.push("HENVALT_STAGE_PIXEL_COLLECTOR_HOST must exactly match the no-send staging Worker");
if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/i.test(env.HENVALT_STAGE_SHOPIFY_STORE ?? "")) {
  errors.push("HENVALT_STAGE_SHOPIFY_STORE must be an explicit myshopify.com development store");
}
for (const key of [
  "HENVALT_STAGE_NO_SEND",
  "HENVALT_STAGE_NETWORK_EGRESS_DENIED",
  "HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED",
  "HENVALT_STAGE_VAULT_SHOPIFY_APP_SECRET_PRESENT",
  "HENVALT_STAGE_INGRESS_SHARED_SECRET_PRESENT",
]) {
  if (env[key] !== "true") errors.push(`${key} must be explicitly confirmed true`);
}
if (env.HENVALT_STAGE_PROVIDER_MODE !== "stub") errors.push("HENVALT_STAGE_PROVIDER_MODE must be stub");
if (errors.length) {
  console.error("SUPABASE STAGING PREFLIGHT: FAIL");
  for (const error of errors) console.error(` - ${error}`);
  process.exit(1);
}
console.log("SUPABASE STAGING PREFLIGHT: PASS (metadata only; no network calls, secret values, or deployments)");
