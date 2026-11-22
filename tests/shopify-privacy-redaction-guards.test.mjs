import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202611220002_shopify_privacy_redaction_guards.sql", "utf8");

test("customer redaction reports no-match before invoking destructive redaction", () => {
  const noMatch = sql.indexOf("if not v_found then");
  const destructive = sql.indexOf("henvalt.redact_shopify_customer_data(p_tenant_id");
  assert.notEqual(noMatch, -1);
  assert.notEqual(destructive, -1);
  assert.ok(noMatch < destructive);
  assert.match(sql, /'matched', false/i);
  assert.match(sql, /'matched', true/i);
});

test("redaction preflight checks tenant-scoped customer and operational PII stores", () => {
  for (const table of ["customers", "checkouts", "canonical_events", "delivery_requests", "messages", "conversation_messages", "email_suppressions", "provider_events", "recovery_interventions", "webhook_events", "processing_errors", "background_jobs", "audit_log"]) {
    assert.ok(sql.toLowerCase().includes("from henvalt." + table + " "), "missing tenant-scoped preflight for " + table);
  }
});

test("shop deletion requires the exact active processing lease", () => {
  assert.match(sql, /v_request\.status <> 'PROCESSING'/i);
  assert.match(sql, /v_request.lease_token is distinct from p_lease_token/i);
  assert.match(sql, /v_request\.lease_expires_at <= now\(\)/i);
  assert.match(sql, /grant execute on function henvalt\.redact_shopify_shop_data_with_lease\(uuid,uuid\) to service_role/i);
});

test("customer redaction and export side effects are fenced by request leases", () => {
  assert.match(sql, /redact_shopify_customer_data_checked_with_lease/);
  assert.match(sql, /export_shopify_customer_data_with_lease/);
  assert.match(sql, /v_request.lease_token is distinct from p_lease_token/i);
  assert.match(sql, /v_request\.lease_expires_at <= now\(\)/i);
  assert.match(sql, /result_payload = null, result_expires_at = null/i);
});

test("legacy null lease metadata fails closed in every side-effect wrapper", () => {
  assert.match(sql, /v_request\.lease_token is distinct from p_lease_token/i);
  assert.match(sql, /v_request\.lease_expires_at is null/i);
});
