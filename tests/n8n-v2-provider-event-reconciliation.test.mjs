import test from "node:test";
import assert from "node:assert/strict";
import { createV2ProviderEventReconciliationRuntime } from "../n8n/v2-provider-event-reconciliation-runtime.mjs";

test("Delivery provider-event reconciliation calls only the bounded service RPC",async()=>{
  const calls=[];
  const runtime=createV2ProviderEventReconciliationRuntime({
    supabaseUrl:"https://project.supabase.co",
    serviceRoleKey:"s".repeat(40),
    fetchImpl:async(url,init)=>{
      calls.push({url,init});
      assert.equal(init.method,"POST");
      assert.equal(init.headers["accept-profile"],"henvalt");
      assert.equal(init.headers["content-profile"],"henvalt");
      assert.equal(init.headers.authorization,"Bearer "+"s".repeat(40));
      assert.deepEqual(JSON.parse(init.body),{p_limit:75});
      return new Response(JSON.stringify({
        accepted:true,reconciled:3,
        automatic_resend_performed:false,
        ambiguous_cost_reservation_released:false,
      }),{status:200});
    },
  });
  const result=await runtime.reconcile({limit:75});
  assert.deepEqual(result,{
    accepted:true,reconciled:3,
    automatic_resend_performed:false,
    ambiguous_cost_reservation_released:false,
    provider_called:false,recipient_pii_returned:false,
  });
  assert.equal(calls.length,1);
  assert.equal(calls[0].url,"https://project.supabase.co/rest/v1/rpc/reconcile_unmatched_shopify_checkout_provider_events_v2");
  assert.equal(calls.some(x=>x.url.includes("api.mailersend.com")),false);
  assert.equal(JSON.stringify(result).includes("recipient@example.com"),false);
});

test("Delivery reconciliation rejects unbounded or malformed RPC acknowledgements",async()=>{
  const runtime=createV2ProviderEventReconciliationRuntime({
    supabaseUrl:"https://project.supabase.co",serviceRoleKey:"s".repeat(40),
    fetchImpl:async()=>new Response(JSON.stringify({
      accepted:true,reconciled:501,
      automatic_resend_performed:false,
      ambiguous_cost_reservation_released:false,
    }),{status:200}),
  });
  await assert.rejects(()=>runtime.reconcile({limit:501}),/invalid_provider_event_reconciliation_limit/);
  await assert.rejects(()=>runtime.reconcile({limit:10}),/provider_event_reconciliation_unconfirmed/);
});

test("Delivery reconciliation fails closed when the RPC acknowledgement is lost",async()=>{
  const runtime=createV2ProviderEventReconciliationRuntime({
    supabaseUrl:"https://project.supabase.co",serviceRoleKey:"s".repeat(40),
    fetchImpl:async()=>new Response("not-json",{status:200}),
  });
  await assert.rejects(()=>runtime.reconcile(),/supabase_rpc_failed/);
});
