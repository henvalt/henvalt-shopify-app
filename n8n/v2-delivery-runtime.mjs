import { createV2HandoffAdapter } from "./v2-handoff-adapter.mjs";

export function createV2DeliveryRuntime({
  supabaseUrl,
  checkoutDeliveryAuthToken,
  pixelDeliveryAuthToken,
  fetchImpl = fetch,
}) {
  const handoff = createV2HandoffAdapter({
    supabaseUrl,
    checkoutBearerToken: checkoutDeliveryAuthToken,
    pixelBearerToken: pixelDeliveryAuthToken,
    fetchImpl,
  });
  return Object.freeze({
    handleClaim: handoff,
  });
}
