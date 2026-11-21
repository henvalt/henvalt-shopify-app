import { createSupabaseServiceRpc } from "./v2-supabase-rpc.mjs";

const DEFAULT_LIMIT=100;

export function createV2ProviderEventReconciliationRuntime({
  supabaseUrl,
  serviceRoleKey,
  fetchImpl=fetch,
}) {
  const rpc=createSupabaseServiceRpc({supabaseUrl,serviceRoleKey,fetchImpl});
  return Object.freeze({
    reconcile: async ({limit=DEFAULT_LIMIT}={}) => {
      if(!Number.isInteger(limit)||limit<1||limit>500) {
        throw new TypeError("invalid_provider_event_reconciliation_limit");
      }
      const events=await rpc("reconcile_unmatched_shopify_checkout_provider_events_v2",{
        p_limit:limit,
      });
      if(events?.accepted!==true||!Number.isInteger(events.reconciled)||
        events.reconciled<0||events.reconciled>limit||
        events.automatic_resend_performed!==false||
        events.ambiguous_cost_reservation_released!==false) {
        throw new Error("provider_event_reconciliation_unconfirmed");
      }
      const pixel=await rpc("reconcile_unmatched_shopify_pixel_provider_events_v2",{p_limit:limit});
      if(pixel?.accepted!==true||!Number.isInteger(pixel.reconciled)||pixel.reconciled<0||pixel.reconciled>limit||
        !Number.isInteger(pixel.deferred)||pixel.deferred<0||pixel.deferred>limit||
        pixel.reconciled+pixel.deferred>limit||pixel.automatic_resend_performed!==false||
        pixel.ambiguous_cost_reservation_released!==false||pixel.provider_called!==false||
        pixel.recipient_pii_returned!==false) {
        throw new Error("pixel_provider_event_reconciliation_unconfirmed");
      }
      const stale=await rpc("mark_stale_shopify_checkout_send_attempts_ambiguous_v2",{
        p_limit:limit,
      });
      if(stale?.accepted!==true||!Number.isInteger(stale.marked_ambiguous)||
        stale.marked_ambiguous<0||stale.marked_ambiguous>limit||
        stale.automatic_retry_performed!==false||
        stale.provider_cost_reservation_released!==false) {
        throw new Error("stale_checkout_attempt_reconciliation_unconfirmed");
      }
      return Object.freeze({
        accepted:true,
        events_reconciled:events.reconciled,
        pixel_events_reconciled:pixel.reconciled,
        pixel_events_deferred:pixel.deferred,
        stale_attempts_marked_ambiguous:stale.marked_ambiguous,
        automatic_resend_performed:false,
        ambiguous_cost_reservation_released:false,
        provider_called:false,
        recipient_pii_returned:false,
      });
    },
  });
}
