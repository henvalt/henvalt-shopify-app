export function createSupabaseServiceRpc({ supabaseUrl, serviceRoleKey, fetchImpl = fetch }) {
  if (typeof supabaseUrl !== "string" || !/^https:\/\//i.test(supabaseUrl) ||
      typeof serviceRoleKey !== "string" || serviceRoleKey.length < 32 ||
      typeof fetchImpl !== "function") {
    throw new TypeError("invalid_supabase_rpc_configuration");
  }
  const base = supabaseUrl.replace(/\/+$/, "");
  return async function rpc(functionName, args) {
    if (typeof functionName !== "string" || !/^[a-z][a-z0-9_]{2,100}$/.test(functionName) ||
        !args || typeof args !== "object" || Array.isArray(args)) {
      throw new TypeError("invalid_rpc_call");
    }
    const response = await fetchImpl(`${base}/rest/v1/rpc/${functionName}`, {
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
    if (!Number.isInteger(seconds) || seconds < 0 || seconds > 86400) {
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
