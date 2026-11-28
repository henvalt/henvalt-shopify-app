import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/202611210004_align_shopify_token_refresh_window.sql", import.meta.url),
  "utf8",
);

test("token refresh claim window matches the ten-minute recovery scheduler", () => {
  assert.match(migration, /access_token_expires_at > now\(\)\+interval '10 minutes'/);
  assert.doesNotMatch(migration, /access_token_expires_at > now\(\)\+interval '5 minutes'/);
  assert.match(migration, /REFRESH_ALREADY_IN_PROGRESS/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /service_role_required/);
});
