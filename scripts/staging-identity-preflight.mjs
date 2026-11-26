#!/usr/bin/env node
import { renderShopifyStagingConfig } from "./render-shopify-staging-config.mjs";
/**
 * HENVALT staging environment identity gate.
 * This only validates explicitly supplied staging metadata. It performs no network calls.
 */
const required = [
  "HENVALT_STAGE_SUPABASE_PROJECT_REF",
  "HENVALT_STAGE_SHOPIFY_CLIENT_ID",
  "HENVALT_STAGE_APPLICATION_URL",
  "HENVALT_STAGE_DASHBOARD_URL",
  "HENVALT_STAGE_PRIVACY_WEBHOOK_URL",
  "HENVALT_STAGE_N8N_BASE_URL",
  "HENVALT_STAGE_INGEST_WORKFLOW_ID",
  "HENVALT_STAGE_RECOVERY_WORKFLOW_ID",
  "HENVALT_STAGE_DELIVERY_WORKFLOW_ID",
  "HENVALT_STAGE_SHOPIFY_STORE",
  "HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL",
  "HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL",
  "HENVALT_STAGE_PROVIDER_MODE",
  "HENVALT_STAGE_NETWORK_EGRESS_DENIED",
  "HENVALT_STAGE_NO_SEND",
  "HENVALT_STAGE_WORKFLOWS_INACTIVE",
  "HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED",
];
const productionProjectRef = "ocyplckdojdubyrsxcxa";
const errors = [];
for (const key of required) {
  if (!process.env[key]?.trim()) errors.push(`missing required staging metadata: ${key}`);
}
const ids = [
  process.env.HENVALT_STAGE_INGEST_WORKFLOW_ID,
  process.env.HENVALT_STAGE_RECOVERY_WORKFLOW_ID,
  process.env.HENVALT_STAGE_DELIVERY_WORKFLOW_ID,
].filter(Boolean);
if (ids.length === 3 && new Set(ids).size !== 3) errors.push("staging n8n workflow IDs must be three distinct identifiers");
const liveProductionWorkflowIds = new Set([
  "VTpfGKNtu1CSQ4Rv", // HENVALT_INGEST
  "3GEDoeCA4paXTaDF", // HENVALT_RECOVERY
  "CvVyybGJZSnklxiZ", // HENVALT_DELIVERY
]);
for (const [key, value] of Object.entries({
  HENVALT_STAGE_INGEST_WORKFLOW_ID: process.env.HENVALT_STAGE_INGEST_WORKFLOW_ID,
  HENVALT_STAGE_RECOVERY_WORKFLOW_ID: process.env.HENVALT_STAGE_RECOVERY_WORKFLOW_ID,
  HENVALT_STAGE_DELIVERY_WORKFLOW_ID: process.env.HENVALT_STAGE_DELIVERY_WORKFLOW_ID,
})) {
  if (value && liveProductionWorkflowIds.has(value)) {
    errors.push(`${key} matches a live production workflow ID`);
  }
}
if (process.env.HENVALT_STAGE_SUPABASE_PROJECT_REF === productionProjectRef) errors.push("staging project ref matches production");
try {
  const dashboard = new URL(process.env.HENVALT_STAGE_DASHBOARD_URL);
  const application = new URL(process.env.HENVALT_STAGE_APPLICATION_URL);
  if (dashboard.protocol !== "https:" || dashboard.username || dashboard.password ||
      dashboard.search || dashboard.hash || dashboard.origin !== application.origin) {
    errors.push("OAuth completion dashboard URL must be explicit HTTPS and match the isolated staging application origin");
  }
  if (["henvalt-dashboard.pages.dev", "henvalt.com", "app.henvalt.com"].includes(dashboard.hostname.toLowerCase())) {
    errors.push("OAuth completion dashboard URL matches a production host");
  }
} catch {
  if (process.env.HENVALT_STAGE_DASHBOARD_URL) errors.push("OAuth completion dashboard URL is malformed");
}
if (process.env.HENVALT_STAGE_PROVIDER_MODE && process.env.HENVALT_STAGE_PROVIDER_MODE !== "stub") errors.push("provider mode must be stub");
if (process.env.HENVALT_STAGE_NETWORK_EGRESS_DENIED !== "true") errors.push("outbound network egress denial must be explicitly confirmed");
if (process.env.HENVALT_STAGE_NO_SEND !== "true") errors.push("no-send safety flag must be explicitly true");
if (process.env.HENVALT_STAGE_WORKFLOWS_INACTIVE !== "true") errors.push("all imported staging workflows must be confirmed inactive");
if (process.env.HENVALT_STAGE_SHOPIFY_DEV_STORE_CONFIRMED !== "true") errors.push("Shopify development store must be explicitly confirmed");
try {
  const n8nUrl = new URL(process.env.HENVALT_STAGE_N8N_BASE_URL);
  if (n8nUrl.protocol !== "https:" || n8nUrl.username || n8nUrl.password) errors.push("staging n8n URL must be HTTPS without embedded credentials");
} catch { if (process.env.HENVALT_STAGE_N8N_BASE_URL) errors.push("staging n8n URL is malformed"); }
if (process.env.HENVALT_STAGE_N8N_BASE_URL && /henvalt26\.app\.n8n\.cloud|prod/i.test(process.env.HENVALT_STAGE_N8N_BASE_URL)) errors.push("n8n URL appears to identify production");
if (process.env.HENVALT_STAGE_SHOPIFY_STORE && !/\.myshopify\.com$/i.test(process.env.HENVALT_STAGE_SHOPIFY_STORE)) errors.push("staging Shopify store must be a myshopify.com development store");
try {
  const callback = new URL(process.env.HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL);
  const expectedHost = process.env.HENVALT_STAGE_SUPABASE_PROJECT_REF + ".supabase.co";
  if (callback.protocol !== "https:" || callback.username || callback.password ||
      callback.hostname !== expectedHost ||
      callback.pathname !== "/functions/v1/henvalt-shopify-oauth/callback") {
    errors.push("Shopify OAuth callback must use the exact staging Supabase project and callback path");
  }
} catch {
  if (process.env.HENVALT_STAGE_SHOPIFY_OAUTH_CALLBACK_URL) errors.push("Shopify OAuth callback URL is malformed");
}
try {
  const ingress = new URL(process.env.HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL);
  if (ingress.protocol !== "https:" || ingress.username || ingress.password ||
      ingress.pathname !== "/shopify/webhooks") {
    errors.push("Shopify webhook ingress must be an HTTPS /shopify/webhooks URL without embedded credentials");
  }
  if (ingress.hostname !== "henvalt-shopify-ingress-staging-no-send.chmuhammadrehan18.workers.dev") {
    errors.push("Shopify webhook ingress must use the dedicated no-send staging Worker hostname");
  }
} catch {
  if (process.env.HENVALT_STAGE_SHOPIFY_WEBHOOK_INGRESS_URL) errors.push("Shopify webhook ingress URL is malformed");
}
try { renderShopifyStagingConfig(process.env); } catch (error) { errors.push(error.message); }
if (errors.length) {
  console.error("STAGING PREFLIGHT: FAIL");
  for (const error of errors) console.error(` - ${error}`);
  process.exit(1);
}
console.log("STAGING PREFLIGHT: PASS (metadata only; no network or credentials accessed)");
