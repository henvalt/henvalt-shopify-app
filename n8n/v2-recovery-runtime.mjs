import { runV2RecoveryTick } from "./v2-recovery-orchestrator.mjs";
import { createSupabaseLeaseFinisher, createSupabaseServiceRpc } from "./v2-supabase-rpc.mjs";

export function createV2RecoveryRuntime({
  supabaseUrl,
  serviceRoleKey,
  handoff,
  fetchImpl = fetch,
}) {
  if (typeof handoff !== "function") {
    throw new TypeError("delivery_subworkflow_handoff_required");
  }
  const rpc = createSupabaseServiceRpc({ supabaseUrl, serviceRoleKey, fetchImpl });
  const finishClaim = createSupabaseLeaseFinisher({ rpc });
  return Object.freeze({
    runTick: ({ workerId, limits } = {}) => runV2RecoveryTick({
      rpc,
      handoff,
      finishClaim,
      workerId,
      limits,
    }),
  });
}
