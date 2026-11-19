import test from "node:test";
import assert from "node:assert/strict";
import { runV2RecoveryTick } from "../n8n/v2-recovery-orchestrator.mjs";
import { createSupabaseLeaseFinisher, createSupabaseServiceRpc } from "../n8n/v2-supabase-rpc.mjs";

test("recovery tick runs all candidate stages in order before claiming opaque work", async () => {
  const calls = [];
  const rpc = async (name, args) => {
    calls.push({ name, args });
    if (name === "claim_shopify_recovery_work_v2") return {
      accepted: true,
      claimed: 2,
      items: [
        { work_type: "CHECKOUT_INTERVENTION", work_id: "11111111-1111-4111-8111-111111111111", lease_id: "22222222-2222-4222-8222-222222222222", tenant_id: "private-tenant", shopify_connection_id: "private-store" },
        { work_type: "PIXEL_OPPORTUNITY", work_id: "33333333-3333-4333-8333-333333333333", lease_id: "44444444-4444-4444-8444-444444444444", tenant_id: "private-tenant", shopify_connection_id: "private-store" },
      ],
    };
    if (name === "refresh_shopify_checkout_recovery_candidates_v2") return { accepted: true, eligible_upserted: 2 };
    if (name === "promote_shopify_checkout_recovery_candidates_v2") return { accepted: true, opportunities_created: 1 };
    if (name === "refresh_shopify_pixel_recovery_candidates_v2") return { accepted: true, candidates_upserted: 3 };
    if (name === "promote_shopify_pixel_recovery_candidates_v2") return { accepted: true, opportunities_created: 2 };
    return { accepted: true, interventions_created: 1 };
  };
  const handoffs = [];
  const finishes = [];
  const result = await runV2RecoveryTick({
    rpc,
    workerId: "worker-v2-01",
    handoff: async claim => {
      handoffs.push(claim);
      return { ...claim, outcome: "HANDOFF_ACCEPTED", retry_after_seconds: 0 };
    },
    finishClaim: async value => { finishes.push(value); return { finished: true }; },
  });
  assert.deepEqual(calls.map(x => x.name), [
    "refresh_shopify_checkout_recovery_candidates_v2",
    "promote_shopify_checkout_recovery_candidates_v2",
    "refresh_shopify_pixel_recovery_candidates_v2",
    "promote_shopify_pixel_recovery_candidates_v2",
    "materialize_shopify_checkout_interventions_v2",
    "claim_shopify_recovery_work_v2",
  ]);
  assert.equal(calls[0].args.p_minimum_inactive_for, "30 minutes");
  assert.equal(calls[2].args.p_inactivity_for, "60 minutes");
  assert.equal(calls[2].args.p_max_age, "24 hours");
  assert.deepEqual(Object.keys(handoffs[0]).sort(), ["correlation_id", "lease_id", "work_id", "work_type", "worker_id"]);
  assert.equal(JSON.stringify(handoffs).includes("private-tenant"), false);
  assert.equal(JSON.stringify(handoffs).includes("private-store"), false);
  assert.equal(finishes.length, 2);
  assert.equal(finishes[0].outcome, "HANDOFF_ACCEPTED");
  assert.equal(result.stages.refresh_checkout.count, 2);
  assert.equal(result.stages.promote_checkout.count, 1);
  assert.equal(result.stages.refresh_pixel.count, 3);
  assert.equal(result.stages.promote_pixel.count, 2);
  assert.equal(result.stages.materialize_checkout.count, 1);
  assert.equal(result.summary.handoff_accepted, 2);
  assert.equal(result.provider_called_by_orchestrator, false);
});

test("a failed or rejected discovery stage stops before claim and handoff", async () => {
  const calls = [];
  let handoffs = 0;
  await assert.rejects(runV2RecoveryTick({
    workerId: "worker-v2-01",
    rpc: async name => { calls.push(name); return name === "promote_shopify_checkout_recovery_candidates_v2" ? { accepted: false, code: "NOT_READY" } : { accepted: true }; },
    handoff: async () => { handoffs++; return { outcome: "DEFERRED", retry_after_seconds: 3600 }; },
    finishClaim: async () => ({ finished: true }),
  }), /v2_stage_rejected:promote_checkout/);
  assert.equal(calls.includes("claim_shopify_recovery_work_v2"), false);
  assert.equal(handoffs, 0);
});

test("tick bounds limits and lease policy before any RPC call", async () => {
  let calls = 0;
  await assert.rejects(runV2RecoveryTick({
    workerId: "worker-v2-01",
    limits: { claimLimit: 101 },
    rpc: async () => { calls++; return { accepted: true, items: [] }; },
    handoff: async () => ({ outcome: "DEFERRED", retry_after_seconds: 3600 }),
    finishClaim: async () => ({ finished: true }),
  }), /invalid_tick_policy/);
  assert.equal(calls, 0);
});

test("service RPC client uses isolated service-role headers and rejects malformed RPC names", async () => {
  const requests = [];
  const rpc = createSupabaseServiceRpc({
    supabaseUrl: "https://project.supabase.co/",
    serviceRoleKey: "s".repeat(40),
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return new Response(JSON.stringify({ accepted: true }), { status: 200 });
    },
  });
  await rpc("claim_shopify_recovery_work_v2", { p_worker_id: "worker-v2-01" });
  assert.match(requests[0].url, /\/rest\/v1\/rpc\/claim_shopify_recovery_work_v2$/);
  assert.equal(requests[0].init.headers["content-profile"], "henvalt");
  assert.equal(requests[0].init.headers.authorization, "Bearer " + "s".repeat(40));
  await assert.rejects(rpc("bad-name;drop", {}), /invalid_rpc_call/);
});

test("lease finisher converts bounded seconds to PostgreSQL interval and checks RPC result", async () => {
  const calls = [];
  const finish = createSupabaseLeaseFinisher({
    rpc: async (name, args) => { calls.push({ name, args }); return { finished: true }; },
  });
  const result = await finish({
    lease_id: "22222222-2222-4222-8222-222222222222",
    worker_id: "worker-v2-01",
    outcome: "DEFERRED",
    retry_after_seconds: 3600,
  });
  assert.equal(result.finished, true);
  assert.equal(calls[0].name, "finish_shopify_recovery_work_claim_v2");
  assert.equal(calls[0].args.p_retry_after, "3600 seconds");
  await assert.rejects(finish({ lease_id: "x", worker_id: "w", outcome: "DEFERRED", retry_after_seconds: 86401 }), /invalid_retry_interval/);
});


test("duplicate work items in a claimed batch are rejected before a second handoff", async () => {
  const item = {
    work_type: "CHECKOUT_INTERVENTION",
    work_id: "11111111-1111-4111-8111-111111111111",
    lease_id: "22222222-2222-4222-8222-222222222222",
  };
  let handoffs = 0;
  let finishes = 0;
  await assert.rejects(runV2RecoveryTick({
    workerId: "worker-v2-01",
    rpc: async name => name === "claim_shopify_recovery_work_v2"
      ? { accepted: true, items: [item, item] }
      : { accepted: true },
    handoff: async claim => { handoffs++; return { ...claim, outcome: "HANDOFF_ACCEPTED", retry_after_seconds: 0 }; },
    finishClaim: async () => { finishes++; return { finished: true }; },
  }), /v2_duplicate_claim_item/);
  assert.equal(handoffs, 1);
  assert.equal(finishes, 1);
});

test("claim RPC cannot return more items than the configured bound", async () => {
  let handoffs = 0;
  await assert.rejects(runV2RecoveryTick({
    workerId: "worker-v2-01",
    limits: { claimLimit: 1 },
    rpc: async name => name === "claim_shopify_recovery_work_v2"
      ? { accepted: true, items: [{}, {}] }
      : { accepted: true },
    handoff: async () => { handoffs++; return { outcome: "DEFERRED", retry_after_seconds: 3600 }; },
    finishClaim: async () => ({ finished: true }),
  }), /v2_claim_items_invalid/);
  assert.equal(handoffs, 0);
});
