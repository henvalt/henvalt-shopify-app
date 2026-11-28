import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migration = await readFile(
  new URL("../supabase/migrations/202611280001_mailersend_retry_lease_credential_release.sql", import.meta.url),
  "utf8",
);

test("retry credential release requires service role and exact generation lease", () => {
  assert.match(migration, /auth\.role\(\) IS DISTINCT FROM 'service_role'/);
  assert.match(migration, /p_generation_number NOT IN \(2,3\)/);
  assert.match(migration, /renew_delivery_retry_job_lease\(/);
  assert.match(migration, /p_retry_job_id,\s*p_retry_worker_id,\s*p_generation_number/);
});

test("retry credential release reuses global interlock and legacy eligibility checks", () => {
  assert.match(migration, /assert_provider_sending_enabled\(\)/);
  assert.match(migration, /get_mailersend_token_for_delivery_legacy_v1\(/);
  assert.match(migration, /REVOKE ALL ON FUNCTION henvalt\.get_mailersend_token_for_delivery\(uuid,uuid,uuid,text,integer\)/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.get_mailersend_token_for_delivery\(uuid,uuid,uuid,text,integer\)\s+TO service_role/);
});
