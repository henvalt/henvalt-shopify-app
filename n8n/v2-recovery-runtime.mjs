import { createV2HandoffAdapter } from "./v2-handoff-adapter.mjs";
import { runV2RecoveryTick } from "./v2-recovery-orchestrator.mjs";
import { createSupabaseLeaseFinisher, createSupabaseServiceRpc } from "./v2-supabase-rpc.mjs";

export function createV2RecoveryRuntime({
  supabaseUrl,
  serviceRoleKey,
  deliveryAuthToken,
  fetchImpl = fetch,
}) {
  if (typeof deliveryAuthToken !== "string" || deliveryAuthToken.length < 16) {
    throw new TypeError("invalid_delivery_auth_configuration");
  }
  const rpc = createSupabaseServiceRpc({ supabaseUrl, serviceRoleKey, fetchImpl });
  const finishClaim = createSupabaseLeaseFinisher({ rpc });
  const handoff = createV2HandoffAdapter({
    supabaseUrl,
    bearerToken: deliveryAuthToken,
    fetchImpl,
    finishClaim,
  });
  return Object.freeze({
    runTick: ({ workerId, limits } = {}) => runV2RecoveryTick({
      rpc,
      handoff,
      workerId,
      limits,
    }),
  });
}
