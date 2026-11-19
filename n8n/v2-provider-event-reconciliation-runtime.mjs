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
      const result=await rpc("reconcile_unmatched_shopify_checkout_provider_events_v2",{
        p_limit:limit,
      });
      if(result?.accepted!==true||!Number.isInteger(result.reconciled)||
        result.reconciled<0||result.reconciled>limit||
        result.automatic_resend_performed!==false||
        result.ambiguous_cost_reservation_released!==false) {
        throw new Error("provider_event_reconciliation_unconfirmed");
      }
      return Object.freeze({
        accepted:true,
        reconciled:result.reconciled,
        automatic_resend_performed:false,
        ambiguous_cost_reservation_released:false,
        provider_called:false,
        recipient_pii_returned:false,
      });
    },
  });
}
