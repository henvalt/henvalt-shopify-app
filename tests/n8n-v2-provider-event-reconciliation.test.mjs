import test from "node:test";
import assert from "node:assert/strict";
import { createV2ProviderEventReconciliationRuntime } from "../n8n/v2-provider-event-reconciliation-runtime.mjs";
import { readFileSync } from "node:fs";
const n8nSpec=readFileSync(new URL("../n8n/v2-n8n-code-node-snippets.md",import.meta.url),"utf8");

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
      const body=JSON.parse(init.body);
      assert.deepEqual(body,{p_limit:75});
      if(url.endsWith("/reconcile_unmatched_shopify_checkout_provider_events_v2")) {
        return new Response(JSON.stringify({
          accepted:true,reconciled:3,
          automatic_resend_performed:false,
          ambiguous_cost_reservation_released:false,
        }),{status:200});
      }
      if(url.endsWith("/mark_stale_shopify_checkout_send_attempts_ambiguous_v2")) {
        return new Response(JSON.stringify({
          accepted:true,marked_ambiguous:2,
          automatic_retry_performed:false,
          provider_cost_reservation_released:false,
        }),{status:200});
      }
      throw new Error("unexpected_rpc");
    },
  });
  const result=await runtime.reconcile({limit:75});
  assert.deepEqual(result,{
    accepted:true,reconciled:3,
    automatic_resend_performed:false,
    ambiguous_cost_reservation_released:false,
    provider_called:false,recipient_pii_returned:false,
  });
  assert.equal(calls.length,2);
  assert.equal(calls[0].url,"https://project.supabase.co/rest/v1/rpc/reconcile_unmatched_shopify_checkout_provider_events_v2");
  assert.equal(calls[1].url,"https://project.supabase.co/rest/v1/rpc/mark_stale_shopify_checkout_send_attempts_ambiguous_v2");
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

test("reconciliation is a scheduled branch inside existing Delivery, not a fourth workflow",()=>{
  assert.match(n8nSpec,/Periodic checkout provider-event reconciliation \(same Delivery workflow\)/);
  assert.match(n8nSpec,/do not create another workflow/);
  assert.match(n8nSpec,/reconcile_unmatched_shopify_checkout_provider_events_v2/);
  assert.match(n8nSpec,/mark_stale_shopify_checkout_send_attempts_ambiguous_v2/);
  assert.match(n8nSpec,/automatic_resend_performed !== false/);
});
