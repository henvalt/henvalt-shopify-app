import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611160003_shopify_oauth_state_app_identity.sql", import.meta.url),
  "utf8",
);
const contract = readFileSync(
  new URL("../docs/app-aware-shopify-oauth-handoff-contract.md", import.meta.url),
  "utf8",
);

test("OAuth state carries an optional registry-backed app identity without rewriting legacy rows", () => {
  assert.match(migration, /ALTER TABLE henvalt\.shopify_oauth_states\s+ADD COLUMN IF NOT EXISTS app_key text/i);
  assert.match(migration, /FOREIGN KEY \(app_key\)\s+REFERENCES henvalt\.shopify_app_registry\(app_key\)/i);
  assert.match(migration, /WHERE app_key IS NOT NULL/);
  assert.match(migration, /nullable preserves legacy OAuth states/i);
  assert.doesNotMatch(migration, /DROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)|TRUNCATE\s|DELETE\s+FROM|UPDATE\s+henvalt\./i);
});

test("OAuth app identity is server-derived and V2 stays disabled by default", () => {
  assert.match(contract, /server derives the app identity from the configured Shopify client/i);
  assert.match(contract, /caller\/browser must never choose or submit/i);
  assert.match(contract, /Zero or multiple matching registry rows fail closed/i);
  assert.match(contract, /feature flag defaulting to false/i);
  assert.match(contract, /raw token never appears in logs or database rows/i);
  assert.match(contract, /No migration has been applied/i);
});
