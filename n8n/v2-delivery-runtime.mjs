import { createV2HandoffAdapter } from "./v2-handoff-adapter.mjs";

export function createV2DeliveryRuntime({
  supabaseUrl,
  deliveryAuthToken,
  fetchImpl = fetch,
}) {
  const handoff = createV2HandoffAdapter({
    supabaseUrl,
    bearerToken: deliveryAuthToken,
    fetchImpl,
  });
  return Object.freeze({
    handleClaim: handoff,
  });
}
