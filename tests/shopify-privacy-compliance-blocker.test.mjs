import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const toml = readFileSync("shopify.app.toml", "utf8");
const webhookSpecs = readFileSync("supabase/functions/henvalt-shopify-oauth/webhook-specs.mjs", "utf8");
const worker = readFileSync("cloudflare/worker.js", "utf8");
const ingest = readFileSync("n8n/fixtures/henvalt-ingest-active-2026-11-21.sanitized.json", "utf8");
const blocker = readFileSync("docs/SHOPIFY_PRIVACY_COMPLIANCE_BLOCKER_2026-11-21.md", "utf8");

test("public App Store privacy compliance remains an explicit release blocker until its handler is implemented", () => {
  const mandatory = ["customers/data_request", "customers/redact", "shop/redact"];
  assert.doesNotMatch(toml, /compliance_topics\s*=/, "Do not configure compliance topics before the handler exists");
  assert.doesNotMatch(webhookSpecs, /customers\/(?:data_request|redact)|shop\/redact/,
    "Compliance topics belong in app TOML, not the ordinary GraphQL subscription loop");
  assert.match(worker, /\/shopify\/webhooks/);
  assert.match(worker, /N8N_INGEST_URL/);
  assert.doesNotMatch(ingest, /privacy_request|customers\/data_request|customers\/redact|shop\/redact/i,
    "The current ingest graph must not be mistaken for a privacy request handler");
  for (const topic of mandatory) assert.ok(blocker.includes(topic), "Missing documented blocker: " + topic);
  assert.match(blocker, /NO-GO/);
  assert.match(blocker, /Do not add a configuration-only declaration/i);
});
