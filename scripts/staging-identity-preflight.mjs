#!/usr/bin/env node
/**
 * HENVALT staging environment identity gate.
 * This only validates explicitly supplied staging metadata. It performs no network calls.
 */
const required = [
  "HENVALT_STAGE_SUPABASE_PROJECT_REF",
  "HENVALT_STAGE_N8N_BASE_URL",
  "HENVALT_STAGE_INGEST_WORKFLOW_ID",
  "HENVALT_STAGE_RECOVERY_WORKFLOW_ID",
  "HENVALT_STAGE_DELIVERY_WORKFLOW_ID",
  "HENVALT_STAGE_SHOPIFY_STORE",
  "HENVALT_STAGE_PROVIDER_MODE",
  "HENVALT_STAGE_NETWORK_EGRESS_DENIED",
  "HENVALT_STAGE_NO_SEND",
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
if (process.env.HENVALT_STAGE_SUPABASE_PROJECT_REF === productionProjectRef) errors.push("staging project ref matches production");
if (process.env.HENVALT_STAGE_PROVIDER_MODE && process.env.HENVALT_STAGE_PROVIDER_MODE !== "stub") errors.push("provider mode must be stub");
if (process.env.HENVALT_STAGE_NETWORK_EGRESS_DENIED !== "true") errors.push("outbound network egress denial must be explicitly confirmed");
if (process.env.HENVALT_STAGE_NO_SEND !== "true") errors.push("no-send safety flag must be explicitly true");
if (process.env.HENVALT_STAGE_N8N_BASE_URL && /henvalt26\\.app\\.n8n\\.cloud|prod/i.test(process.env.HENVALT_STAGE_N8N_BASE_URL)) errors.push("n8n URL appears to identify production");
if (process.env.HENVALT_STAGE_SHOPIFY_STORE && !/\\.myshopify\\.com$/i.test(process.env.HENVALT_STAGE_SHOPIFY_STORE)) errors.push("staging Shopify store must be a myshopify.com development store");
if (errors.length) {
  console.error("STAGING PREFLIGHT: FAIL");
  for (const error of errors) console.error(` - ${error}`);
  process.exit(1);
}
console.log("STAGING PREFLIGHT: PASS (metadata only; no network or credentials accessed)");
