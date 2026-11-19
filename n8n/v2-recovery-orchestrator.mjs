const DEFAULTS = Object.freeze({
  checkoutInactivity: "30 minutes",
  pixelInactivity: "60 minutes",
  pixelMaxAge: "24 hours",
  candidateLimit: 100,
  pixelCandidateLimit: 200,
  claimLimit: 25,
  leaseSeconds: 180,
});

function assertStageAccepted(name, result) {
  if (!result || typeof result !== "object" || Array.isArray(result) || result.accepted !== true) {
    throw new Error(`v2_stage_rejected:${name}`);
  }
  return result;
}

function boundedInt(value, fallback, min, max) {
  const n = Number(value ?? fallback);
  if (!Number.isInteger(n) || n < min || n > max) throw new TypeError("invalid_tick_policy");
  return n;
}

export async function runV2RecoveryTick({
  rpc,
  handoff,
  workerId,
  limits = {},
}) {
  if (typeof rpc !== "function" || typeof handoff !== "function" ||
      typeof workerId !== "string" || !/^[A-Za-z0-9._:-]{3,80}$/.test(workerId)) {
    throw new TypeError("invalid_tick_configuration");
  }
  const candidateLimit = boundedInt(limits.candidateLimit, DEFAULTS.candidateLimit, 1, 500);
  const pixelCandidateLimit = boundedInt(limits.pixelCandidateLimit, DEFAULTS.pixelCandidateLimit, 1, 500);
  const claimLimit = boundedInt(limits.claimLimit, DEFAULTS.claimLimit, 1, 100);
  const leaseSeconds = boundedInt(limits.leaseSeconds, DEFAULTS.leaseSeconds, 30, 900);

  // The order is intentional: discover/refresh first, promote second, materialize
  // checkout interventions third, then claim and hand off opaque work identifiers.
  const stages = [
    ["refresh_checkout", "refresh_shopify_checkout_recovery_candidates_v2", {
      p_minimum_inactive_for: DEFAULTS.checkoutInactivity,
      p_limit: candidateLimit,
    }],
    ["promote_checkout", "promote_shopify_checkout_recovery_candidates_v2", {
      p_limit: candidateLimit,
    }],
    ["refresh_pixel", "refresh_shopify_pixel_recovery_candidates_v2", {
      p_inactivity_for: DEFAULTS.pixelInactivity,
      p_max_age: DEFAULTS.pixelMaxAge,
      p_limit: pixelCandidateLimit,
    }],
    ["promote_pixel", "promote_shopify_pixel_recovery_candidates_v2", {
      p_limit: pixelCandidateLimit,
    }],
    ["materialize_checkout", "materialize_shopify_checkout_interventions_v2", {
      p_limit: candidateLimit,
    }],
  ];

  const stageResults = {};
  for (const [key, functionName, args] of stages) {
    stageResults[key] = assertStageAccepted(key, await rpc(functionName, args));
  }

  const claim = assertStageAccepted("claim_work", await rpc("claim_shopify_recovery_work_v2", {
    p_worker_id: workerId,
    p_limit: claimLimit,
    p_lease_seconds: leaseSeconds,
  }));
  if (!Array.isArray(claim.items)) throw new Error("v2_claim_items_invalid");

  const summary = {
    worker_id: workerId,
    claimed: claim.items.length,
    handoff_accepted: 0,
    terminal: 0,
    deferred: 0,
    lease_finish_unconfirmed: 0,
    outcomes: [],
  };

  for (const item of claim.items) {
    // Strip all tenant/store/opportunity metadata returned by the SQL claim RPC.
    // The adapter receives only the opaque work ID, lease ID, type and worker.
    const safeClaim = {
      work_type: item?.work_type,
      work_id: item?.work_id,
      lease_id: item?.lease_id,
      worker_id: workerId,
      correlation_id: `v2:${String(item?.work_id ?? "")}`,
    };
    const result = await handoff(safeClaim);
    const outcome = result?.outcome;
    if (outcome === "HANDOFF_ACCEPTED") summary.handoff_accepted += 1;
    else if (outcome === "TERMINAL") summary.terminal += 1;
    else if (outcome === "DEFERRED") summary.deferred += 1;
    else throw new Error("v2_handoff_outcome_invalid");
    if (result.lease_finished !== true) summary.lease_finish_unconfirmed += 1;
    summary.outcomes.push({
      work_type: result.work_type,
      work_id: result.work_id,
      outcome,
      lease_finished: result.lease_finished === true,
    });
  }

  return Object.freeze({
    accepted: true,
    worker_id: workerId,
    stages: Object.freeze(Object.fromEntries(
      Object.entries(stageResults).map(([key, value]) => [key, {
        accepted: value.accepted === true,
        count: Number(value.upserted ?? value.promoted ?? value.created ?? value.interventions_created ?? 0) || 0,
      }])
    )),
    summary: Object.freeze(summary),
    delivery_authorized_by_orchestrator: false,
    provider_called_by_orchestrator: false,
    recipient_pii_returned: false,
  });
}

export { DEFAULTS as V2_RECOVERY_TICK_DEFAULTS };
