import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../docs/sql/stage-0-shopify-app-identity-registry-candidate.sql", import.meta.url),
  "utf8",
);
const normalized = migration.toLowerCase();

test("Stage 0 identity candidate is explicitly preparation-only and never applied", () => {
  assert.match(migration, /PREPARATION BRANCH ONLY — NOT AN APPLIED MIGRATION/);
  assert.match(migration, /intentionally outside supabase\/migrations/i);
  assert.match(migration, /has NOT been executed against Supabase/i);
});

test("Stage 0 creates a server-side app registry without storing credentials", () => {
  assert.match(normalized, /create table if not exists henvalt\.shopify_app_registry/);
  assert.match(normalized, /shopify_client_id text not null unique/);
  assert.match(normalized, /distribution_type in \('custom', 'public'\)/);
  assert.match(normalized, /secret_reference text not null/);
  assert.match(normalized, /secret_reference_not_token/);
  assert.doesNotMatch(normalized, /shopify_api_secret\s+text/);
  assert.doesNotMatch(normalized, /access_token\s+text/);
});

test("Stage 0 preserves legacy rows and does not guess app provenance", () => {
  assert.match(normalized, /add column if not exists app_key text/);
  assert.match(normalized, /do not backfill legacy app_key values/);
  assert.match(normalized, /do not insert legacy\/public app rows in this stage/);
  assert.doesNotMatch(normalized, /update henvalt\.shopify_connections\s+set app_key/i);
  assert.doesNotMatch(normalized, /update henvalt\.shopify_oauth_states\s+set app_key/i);
});

test("Stage 0 preserves shop-domain uniqueness and adds tenant-connection candidate key", () => {
  assert.match(normalized, /unique \(tenant_id, id\)/);
  assert.match(normalized, /references henvalt\.shopify_app_registry\(app_key\)/);
  assert.match(normalized, /not valid/);
  assert.doesNotMatch(normalized, /drop constraint[^;]*shop_domain/i);
});

test("Stage 0 keeps app registry backend-only", () => {
  assert.match(normalized, /enable row level security/);
  assert.match(normalized, /revoke all on table henvalt\.shopify_app_registry from public, anon, authenticated/);
  assert.match(normalized, /grant select, insert, update, delete on table henvalt\.shopify_app_registry to service_role/);
});
