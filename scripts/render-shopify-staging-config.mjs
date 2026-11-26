import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const productionConfig = readFileSync(resolve(root, "shopify.app.toml"), "utf8");
const productionClientId = productionConfig.match(/^client_id\s*=\s*"([^"]+)"/m)?.[1];
const productionProjectRef = "ocyplckdojdubyrsxcxa";

function required(env, key) {
  const value = env[key]?.trim();
  if (!value) throw new Error(`missing required staging value: ${key}`);
  return value;
}

function httpsUrl(value, key) {
  let url;
  try { url = new URL(value); } catch { throw new Error(`${key} must be a valid URL`); }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error(`${key} must be HTTPS without credentials, query or fragment`);
  }
  return url;
}

export function renderShopifyStagingConfig(env = process.env) {
  const clientId = required(env, "HENVALT_STAGE_SHOPIFY_CLIENT_ID");
  const projectRef = required(env, "HENVALT_STAGE_SUPABASE_PROJECT_REF");
  const applicationUrl = httpsUrl(required(env, "HENVALT_STAGE_APPLICATION_URL"), "HENVALT_STAGE_APPLICATION_URL");
  const privacyUrl = httpsUrl(required(env, "HENVALT_STAGE_PRIVACY_WEBHOOK_URL"), "HENVALT_STAGE_PRIVACY_WEBHOOK_URL");
  if (clientId === productionClientId) throw new Error("staging Shopify client ID matches production");
  if (!/^[a-z0-9]{20}$/.test(projectRef) || projectRef === productionProjectRef) {
    throw new Error("staging Supabase project ref is invalid or matches production");
  }
  if (["henvalt-dashboard.pages.dev", "henvalt.com", "app.henvalt.com", "n8n.henvalt.com"].includes(applicationUrl.hostname)) {
    throw new Error("staging application URL matches production dashboard");
  }
  if (privacyUrl.hostname !== `${projectRef}.supabase.co` ||
      privacyUrl.pathname !== "/functions/v1/henvalt-shopify-privacy") {
    throw new Error("staging privacy webhook must use the exact staging Supabase project and function path");
  }
  const callback = `https://${projectRef}.supabase.co/functions/v1/henvalt-shopify-oauth/callback`;
  const scopes = productionConfig.match(/^scopes\s*=\s*"([^"]+)"/m)?.[1];
  if (!scopes) throw new Error("production Shopify scopes could not be read safely");
  return [
    `client_id = "${clientId}"`,
    'name = "HENVALT Staging"',
    `application_url = "${applicationUrl.origin}${applicationUrl.pathname.replace(/\/$/, "")}"`,
    "embedded = false",
    "",
    "[build]",
    "automatically_update_urls_on_dev = false",
    "",
    "[access_scopes]",
    `scopes = "${scopes}"`,
    "use_legacy_install_flow = true",
    "",
    "[auth]",
    "redirect_urls = [",
    `  "${callback}"`,
    "]",
    "",
    "[webhooks]",
    'api_version = "2026-10"',
    "",
    "[[webhooks.subscriptions]]",
    'compliance_topics = ["customers/data_request", "customers/redact", "shop/redact"]',
    `uri = "${privacyUrl.origin}${privacyUrl.pathname}"`,
    "",
  ].join("\n");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const output = resolve(process.argv[2] || "shopify.app.staging.toml");
  const rendered = renderShopifyStagingConfig();
  writeFileSync(output, rendered, { flag: "wx" });
  console.log(`Wrote isolated staging Shopify config to ${output}`);
}
