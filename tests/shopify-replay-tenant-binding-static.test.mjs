import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202611220007_shopify_replay_tenant_binding.sql","utf8");

test("explicit tenant wrappers bind tenant to the leased replay job and stored webhook", () => {
  assert.match(migration,/assert_shopify_replay_tenant_for_write/);
  assert.match(migration,/v_job_tenant IS DISTINCT FROM p_tenant_id/);
  assert.match(migration,/w\.tenant_id = v_job_tenant/);
  for (const name of ["upsert_customer_fenced","apply_shopify_email_consent_update_fenced","bind_session_alias_fenced","upsert_canonical_event_fenced","upsert_checkout_fenced","create_opportunity_idempotent_fenced","deactivate_shopify_connection_on_uninstall_fenced"]) {
    const start=migration.indexOf("CREATE OR REPLACE FUNCTION henvalt."+name+"(");
    assert.ok(start>=0,name);
    const end=migration.indexOf("$function$;",start);
    const body=migration.slice(start,end);
    assert.match(body,/assert_shopify_replay_tenant_for_write\(p_job_id,p_worker_id,p_lease_id,p_tenant_id\)/,name);
  }
});

test("webhook lifecycle writes are bound to the exact webhook in the claimed job", () => {
  assert.match(migration,/assert_shopify_replay_webhook_for_write/);
  assert.match(migration,/v_job_webhook_id IS DISTINCT FROM p_webhook_id::text/);
  const canonicalStart=migration.indexOf("CREATE OR REPLACE FUNCTION henvalt.upsert_canonical_event_fenced(");
  const canonicalEnd=migration.indexOf("$function$;",canonicalStart);
  assert.match(migration.slice(canonicalStart,canonicalEnd),/assert_shopify_replay_webhook_for_write\(p_job_id,p_worker_id,p_lease_id,p_webhook_event_id\)/);
  for (const name of ["mark_webhook_processed_fenced","mark_webhook_failed_fenced"]) {
    const start=migration.indexOf("CREATE OR REPLACE FUNCTION henvalt."+name+"(");
    const end=migration.indexOf("$function$;",start);
    assert.match(migration.slice(start,end),/assert_shopify_replay_webhook_for_write\(p_job_id,p_worker_id,p_lease_id,p_webhook_id\)/,name);
  }
});

test("tenant binding helper functions remain private to service role", () => {
  for (const name of ["assert_shopify_replay_tenant_for_write","assert_shopify_replay_webhook_for_write"]) {
    assert.ok(migration.includes("REVOKE ALL ON FUNCTION henvalt."+name+"("));
    assert.ok(migration.includes("GRANT EXECUTE ON FUNCTION henvalt."+name+"("));
  }
});
