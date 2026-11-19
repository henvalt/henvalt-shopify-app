const ALLOWED_RPC = new Set([
  "refresh_shopify_checkout_recovery_candidates_v2",
  "promote_shopify_checkout_recovery_candidates_v2",
  "refresh_shopify_pixel_recovery_candidates_v2",
  "promote_shopify_pixel_recovery_candidates_v2",
  "materialize_shopify_checkout_interventions_v2",
  "claim_shopify_recovery_work_v2",
  "finish_shopify_recovery_work_claim_v2",
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createSupabaseServiceRpc({ supabaseUrl, serviceRoleKey, fetchImpl = fetch }) {
  let trustedUrl = false;
  try {
    const parsed = new URL(supabaseUrl);
    trustedUrl = parsed.protocol === "https:" && /^[a-z0-9-]+\.supabase\.co$/i.test(parsed.hostname) &&
      (parsed.pathname === "" || parsed.pathname === "/") && !parsed.port && !parsed.search && !parsed.hash && !parsed.username && !parsed.password;
  } catch { trustedUrl = false; }
  if (!trustedUrl ||
      typeof serviceRoleKey !== "string" || serviceRoleKey.length < 32 ||
      typeof fetchImpl !== "function") {
    throw new TypeError("invalid_supabase_rpc_configuration");
  }
  const base = supabaseUrl.replace(/\/+$/, "");
  return async function rpc(functionName, args) {
    if (typeof functionName !== "string" || !ALLOWED_RPC.has(functionName) ||
        !args || typeof args !== "object" || Array.isArray(args)) {
      throw new TypeError("invalid_rpc_call");
    }
    let response;
    try {
      response = await fetchImpl(`${base}/rest/v1/rpc/${functionName}`, {
        method: "POST",
        headers: {
          apikey: serviceRoleKey,
          authorization: `Bearer ${serviceRoleKey}`,
          "content-type": "application/json",
          "accept-profile": "henvalt",
          "content-profile": "henvalt",
        },
        body: JSON.stringify(args),
        signal: AbortSignal.timeout(15000),
      });
    } catch {
      throw new Error("supabase_rpc_transport_failed");
    }
    let payload = null;
    try { payload = await response.json(); } catch { /* handled as generic failure */ }
    if (!response.ok || !payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw new Error("supabase_rpc_failed");
    }
    return payload;
  };
}

export function createSupabaseLeaseFinisher({ rpc }) {
  if (typeof rpc !== "function") throw new TypeError("invalid_rpc_client");
  return async function finishClaim({ lease_id, worker_id, outcome, retry_after_seconds }) {
    const seconds = Number(retry_after_seconds);
    if (!UUID.test(lease_id ?? "") || typeof worker_id !== "string" || !/^[A-Za-z0-9._:-]{3,80}$/.test(worker_id) ||
        !["HANDOFF_ACCEPTED", "TERMINAL", "DEFERRED"].includes(outcome) ||
        !Number.isInteger(seconds) || seconds < 0 || seconds > 86400) {
      throw new TypeError("invalid_retry_interval");
    }
    return await rpc("finish_shopify_recovery_work_claim_v2", {
      p_lease_id: lease_id,
      p_worker_id: worker_id,
      p_outcome: outcome,
      p_retry_after: `${seconds} seconds`,
    });
  };
}
