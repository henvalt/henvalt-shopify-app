import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql=readFileSync("supabase/migrations/202611220008_shopify_replay_object_tenant_binding.sql",
  "supabase/migrations/202611220013_shopify_order_edit_revenue_reconciliation.sql","utf8");
const wrappers=[
 ["resolve_identity_fenced","henvalt.resolve_identity(",["'canonical_events',p_event_id"]],
 ["upsert_checkout_fenced","henvalt.upsert_checkout(",["'customers',p_customer_id"]],
 ["create_opportunity_idempotent_fenced","henvalt.create_opportunity_idempotent(",["'canonical_events',p_source_event_id","'customers',p_customer_id","'checkouts',p_checkout_id"]],
 ["apply_eligibility_fenced","henvalt.apply_eligibility(",["'opportunities',p_opportunity_id"]],
 ["create_recovery_sequence_fenced","henvalt.create_recovery_sequence(",["'opportunities',p_opportunity_id"]],
 ["create_intervention_and_enqueue_fenced","henvalt.create_intervention_and_enqueue(",["'recovery_sequences',p_recovery_id"]],
 ["project_order_from_event_fenced","henvalt.project_order_from_event(",["'canonical_events',p_event_id"]],
 ["evaluate_order_attribution_fenced","henvalt.evaluate_order_attribution(",["'orders',p_order_id"]],
 ["create_revenue_adjustment_fenced","henvalt.create_revenue_adjustment(",["'orders',p_order_id","'canonical_events',p_source_event_id"]],
 ["process_shopify_revenue_adjustment_fenced","henvalt.process_shopify_revenue_adjustment(",["'canonical_events',p_event_id"]],
 ["stop_recovery_after_order_fenced","henvalt.stop_recovery_after_order(",["'order_attributions',p_attribution_id"]],
 ["post_recovery_to_ledger_and_measure_billing_fenced","henvalt.post_recovery_to_ledger_and_measure_billing(",["'order_attributions',p_attribution_id"]]
];

test("object tenant guard uses explicit allow-listed tenant-owned tables",()=>{
 assert.match(sql,/assert_shopify_replay_tenant_for_write\(p_job_id,p_worker_id,p_lease_id,p_tenant_id\)/);
 for(const table of ["customers","checkouts","canonical_events","opportunities","orders","order_attributions","recovery_sequences","recovery_interventions"])
  assert.match(sql,new RegExp("FROM henvalt\\."+table+" x WHERE x\\.id=p_object_id AND x\\.tenant_id=p_tenant_id"));
 assert.match(sql,/SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED/);
});

test("every UUID-only fenced business wrapper validates its target ownership before legacy mutation",()=>{
 for(const [name,mutation,expectedGuards] of wrappers){
  const start=sql.indexOf("CREATE OR REPLACE FUNCTION henvalt."+name+"(");
  assert.ok(start>=0,"missing "+name);
  const end=sql.indexOf("$function$;",start);
  const body=sql.slice(start,end);
  const mutationAt=body.indexOf(mutation);
  assert.ok(mutationAt>=0,name+" missing expected legacy mutation "+mutation);
  for(const guard of expectedGuards){
   const guardAt=body.indexOf("assert_shopify_replay_object_tenant");
   const exactGuard=body.indexOf(guard);
   assert.ok(guardAt>=0,name+" missing object tenant check");
   assert.ok(exactGuard>=0,name+" missing target ownership check "+guard);
   assert.ok(exactGuard<mutationAt,name+" target check must precede mutation: "+guard);
  }
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
 assert.match(sql,/LEFT JOIN henvalt\.orders o ON o\.id=x\.order_id/);
 assert.match(sql,/LEFT JOIN henvalt\.webhook_events w ON w\.id=x\.webhook_event_id/);
 assert.match(sql,/LEFT JOIN henvalt\.recovery_sequences s ON s\.id=x\.recovery_id/);
 assert.match(sql,/LEFT JOIN henvalt\.recovery_interventions i ON i\.id=x\.matched_intervention_id/);
});

test("all replay mutation-map RPCs have a candidate fenced implementation",()=>{
 const map=JSON.parse(readFileSync("n8n/shopify-ingest-replay-write-map.json","utf8"));
 const sources=[
  "supabase/migrations/202611210009_shopify_replay_business_write_fencing.sql",
  "supabase/migrations/202611210010_shopify_replay_complete_ingest_write_fencing.sql",
  "supabase/migrations/202611220007_shopify_replay_tenant_binding.sql",
  "supabase/migrations/202611220008_shopify_replay_object_tenant_binding.sql"
 ].map(path=>readFileSync(path,"utf8")).join("\\n");
 for(const item of map.replay_mutations){
  assert.ok(sources.includes("FUNCTION henvalt."+item.fenced_rpc+"("),"missing fenced RPC "+item.fenced_rpc);
 }
});

test("disposable PostgreSQL acceptance exercises every tenant relationship edge",()=>{
 const fixture=readFileSync("tests/shopify-replay-object-tenant-graph-postgres-acceptance.sql","utf8");
 for(const table of ["checkouts","canonical_events","opportunities","orders","recovery_sequences","recovery_interventions","order_attributions"])
  assert.ok(fixture.includes("expect_replay_graph_rejection('"+table+"'"),"missing graph rejection fixture "+table);
 assert.match(fixture,/SHOPIFY_REPLAY_OBJECT_TENANT_GRAPH_ACCEPTANCE_PASSED/);
 const workflow=readFileSync(".github/workflows/provider-send-interlock-static.yml","utf8");
 assert.ok(workflow.includes("shopify-replay-object-tenant-graph-postgres-acceptance.sql"),"graph acceptance is not wired into CI");
});

test("standalone object graph helper rejects foreign and missing roots",()=>{
 assert.match(sql,/SHOPIFY_REPLAY_OBJECT_GRAPH_ROOT_TENANT_MISMATCH/);
 assert.match(sql,/IF NOT COALESCE\(v_root_exists,false\) THEN/);
 const fixture=readFileSync("tests/shopify-replay-object-tenant-graph-postgres-acceptance.sql","utf8");
 assert.match(fixture,/expect_replay_graph_rejection\('customers','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2'\)/);
 assert.match(fixture,/expect_replay_graph_rejection\('customers','cccccccc-cccc-4ccc-8ccc-cccccccccc33'\)/);
});

test("object graph helper fails closed for unknown tables and handles customer roots",()=>{
 assert.match(sql,/WHEN 'customers' THEN[\s\S]*?FROM henvalt\.customers x/);
 assert.match(sql,/ELSE\s+RAISE EXCEPTION 'SHOPIFY_REPLAY_OBJECT_TABLE_NOT_ALLOWED'/);
 assert.doesNotMatch(sql,/ELSE\s+v_valid := true/);
});
