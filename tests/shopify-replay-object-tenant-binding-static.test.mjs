import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql=readFileSync("supabase/migrations/202611220008_shopify_replay_object_tenant_binding.sql","utf8");
const wrappers=[
 ["resolve_identity_fenced","canonical_events"],
 ["upsert_checkout_fenced","customers"],
 ["create_opportunity_idempotent_fenced","canonical_events"],
 ["apply_eligibility_fenced","opportunities"],
 ["create_recovery_sequence_fenced","opportunities"],
 ["create_intervention_and_enqueue_fenced","recovery_sequences"],
 ["project_order_from_event_fenced","canonical_events"],
 ["evaluate_order_attribution_fenced","orders"],
 ["create_revenue_adjustment_fenced","orders"],
 ["process_shopify_revenue_adjustment_fenced","canonical_events"],
 ["stop_recovery_after_order_fenced","order_attributions"],
 ["post_recovery_to_ledger_and_measure_billing_fenced","order_attributions"]
];

test("object tenant guard uses explicit allow-listed tenant-owned tables",()=>{
 assert.match(sql,/assert_shopify_replay_tenant_for_write\(p_job_id,p_worker_id,p_lease_id,p_tenant_id\)/);
 for(const table of ["customers","checkouts","canonical_events","opportunities","orders","order_attributions","recovery_sequences","recovery_interventions"])
  assert.match(sql,new RegExp("FROM henvalt\\."+table+" x WHERE x\\.id=p_object_id AND x\\.tenant_id=p_tenant_id"));
 assert.match(sql,/SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED/);
});

test("every UUID-only fenced business wrapper validates its target ownership before legacy mutation",()=>{
 for(const [name,table] of wrappers){
  const start=sql.indexOf("CREATE OR REPLACE FUNCTION henvalt."+name+"(");
  assert.ok(start>=0,"missing "+name);
  const end=sql.indexOf("$function$;",start);
  const body=sql.slice(start,end);
  assert.ok(body.includes("assert_shopify_replay_object_tenant"),name+" missing object tenant check");
  assert.ok(body.indexOf("assert_shopify_replay_object_tenant") < body.indexOf("RETURN henvalt."),name+" guard must precede mutation");
 }
});

test("webhook event state and uninstall mutations stay bound to job webhook",()=>{
 for(const name of ["deactivate_shopify_connection_on_uninstall_fenced","defer_payment_webhook_reconciliation_fenced"]){
  const start=sql.indexOf("CREATE OR REPLACE FUNCTION henvalt."+name+"(");
  const end=sql.indexOf("$function$;",start);
  assert.match(sql.slice(start,end),/assert_shopify_replay_webhook_for_write/);
 }
});

test("redefined object-fenced wrappers remain service-role-only",()=>{
 for(const [name] of wrappers){
  const start=sql.indexOf("REVOKE ALL ON FUNCTION henvalt."+name+"(");
  assert.ok(start>=0,"missing PUBLIC revoke "+name);
  const tail=sql.slice(start);
  assert.ok(tail.indexOf("GRANT EXECUTE ON FUNCTION henvalt."+name+"(")>=0,"missing service grant "+name);
 }
});

test("object graph checks reject cross-tenant foreign-key edges, not only root rows",()=>{
 assert.match(sql,/assert_shopify_replay_object_graph_tenant/);
 for(const table of ["customers","checkouts","canonical_events","opportunities","orders","order_attributions","recovery_sequences","recovery_interventions"])
  assert.ok(sql.includes("WHEN '"+table+"'"),"missing graph branch "+table);
 assert.match(sql,/SHOPIFY_REPLAY_OBJECT_GRAPH_TENANT_MISMATCH/);
 assert.match(sql,/LEFT JOIN henvalt\\.orders o ON o\\.id=x\\.order_id/);
 assert.match(sql,/LEFT JOIN henvalt\\.webhook_events w ON w\\.id=x\\.webhook_event_id/);
 assert.match(sql,/LEFT JOIN henvalt\\.recovery_sequences s ON s\\.id=x\\.recovery_id/);
 assert.match(sql,/LEFT JOIN henvalt\\.recovery_interventions i ON i\\.id=x\\.matched_intervention_id/);
});
