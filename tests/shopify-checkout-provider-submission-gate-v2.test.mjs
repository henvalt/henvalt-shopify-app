import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration=readFileSync("supabase/migrations/202611190005_shopify_checkout_provider_submission_gate_v2.sql","utf8");
const edge=readFileSync("supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts","utf8");
const workflow=readFileSync(".github/workflows/shopify-identity-v2-validation.yml","utf8");
const sql=readFileSync("tests/sql/shopify-checkout-provider-submission-gate-v2.test.sql","utf8");

test("checkout final gate rebinds attempt, permit, reservation and exact store lineage",()=>{
  assert.match(migration,/JOIN henvalt\.shopify_delivery_permits_v2[\s\S]*?permit_row\.send_attempt_id=a\.id[\s\S]*?JOIN henvalt\.shopify_delivery_cost_reservations_v2[\s\S]*?reservation_row\.send_attempt_id=a\.id/);
  assert.match(migration,/sc\.id=a\.shopify_connection_id AND sc\.tenant_id=a\.tenant_id/);
  assert.match(migration,/v_attempt\.connection_active IS DISTINCT FROM true/);
  assert.match(migration,/PERFORM 1[\s\S]*?FROM henvalt\.shopify_connections[\s\S]*?FOR UPDATE/);
  assert.match(migration,/v_attempt\.connection_app_key IS DISTINCT FROM v_attempt\.app_key/);
  assert.match(migration,/v_attempt\.tenant_status<>'ACTIVE'/);
});

test("checkout final gate rechecks checkout, consent, order, suppression, privacy, sender and cost",()=>{
  for(const pattern of [
    /v_attempt\.intervention_status<>'AUTHORIZED'/,
    /v_attempt\.checkout_status IS DISTINCT FROM 'OPEN'/,
    /v_attempt\.marketing_state IS DISTINCT FROM 'SUBSCRIBED'/,
    /shopify_order_identity_v2/,
    /shopify_delivery_suppressions_v2/,
    /shopify_customer_redaction_guards_v2/,
    /v_attempt\.sender_status<>'ACTIVE'/,
    /v_attempt\.reservation_status<>'RESERVED'/,
  ]) assert.match(migration,pattern);
});

test("checkout Edge Function invokes final gate after permit consumption and before MailerSend",()=>{
  const consume=edge.indexOf('rpc("consume_shopify_delivery_permit_v2"');
  const gate=edge.indexOf('rpc("authorize_shopify_delivery_provider_submission_v2"');
  const provider=edge.indexOf('fetch("https://api.mailersend.com/v1/email"');
  assert.ok(consume>=0&&gate>consume&&provider>gate);
  assert.match(edge,/if\(finalGate\?\.authorized!==true\)\{await record\(attempt,"FAILED"\)/);
});

test("final gate is service-role-only and registered in migration and SQL CI",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION henvalt\.authorize_shopify_delivery_provider_submission_v2\(uuid,text\)[\s\S]*?FROM PUBLIC,anon,authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION henvalt\.authorize_shopify_delivery_provider_submission_v2\(uuid,text\)[\s\S]*?TO service_role/);
  assert.match(workflow,/202611190005_shopify_checkout_provider_submission_gate_v2\.sql/);
  assert.match(workflow,/tests\/sql\/shopify-checkout-provider-submission-gate-v2\.test\.sql/);
  assert.match(sql,/pg_get_functiondef/);
});
