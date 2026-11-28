const STAGING_SUPABASE_URL = "https://xidhtmrfvsgfmyltjuja.supabase.co";
const SCAN_ARGUMENTS = Object.freeze({
  p_inactivity_minutes: 60,
  p_max_age_hours: 48,
  p_limit: 100,
});
const SCAN_STAGES = Object.freeze([
  "process_abandoned_checkout_candidates",
  "process_abandoned_cart_candidates",
  "process_browse_abandonment_candidates",
]);

function response(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function constantTimeEqual(left, right) {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
  return mismatch === 0;
}

export function createRecoveryScanHandler({
  supabaseUrl,
  serviceRoleKey,
  fetchImpl = fetch,
}) {
  return async (request) => {
    if (request.method !== "POST") {
      return response(405, { error: "method_not_allowed" });
    }

    if (supabaseUrl !== STAGING_SUPABASE_URL || !serviceRoleKey) {
      return response(503, { error: "staging_worker_not_configured" });
    }

    const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!constantTimeEqual(bearer, serviceRoleKey)) {
      return response(401, { error: "service_role_required" });
    }

    // Candidate discovery is deliberately server-controlled. The caller cannot
    // widen the age window, lower the inactivity threshold, or raise the batch.
    for (const rpc of SCAN_STAGES) {
      let rpcResponse;
      try {
        rpcResponse = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/${rpc}`, {
          method: "POST",
          redirect: "error",
          headers: {
            apikey: serviceRoleKey,
            authorization: `Bearer ${serviceRoleKey}`,
            "content-type": "application/json",
            accept: "application/json",
            "accept-profile": "henvalt",
            "content-profile": "henvalt",
          },
          body: JSON.stringify(SCAN_ARGUMENTS),
          signal: AbortSignal.timeout(10000),
        });
      } catch {
        return response(502, { error: "recovery_scan_upstream_unavailable", stage: rpc });
      }

      if (!rpcResponse.ok) {
        // Do not return PostgREST bodies: they can contain SQL details or
        // merchant data. The failed stage is enough for safe operator tracing.
        return response(502, { error: "recovery_scan_stage_failed", stage: rpc });
      }

      // Consume the response so the connection can be reused, but never expose
      // candidate records or customer data to the scheduler caller.
      await rpcResponse.arrayBuffer();
    }

    return response(200, {
      ok: true,
      mode: "staging_candidate_scan",
      stages_completed: SCAN_STAGES,
    });
  };
}

export { SCAN_ARGUMENTS, SCAN_STAGES, STAGING_SUPABASE_URL };
