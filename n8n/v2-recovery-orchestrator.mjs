const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WORK_TYPES = new Set(["CHECKOUT_INTERVENTION", "PIXEL_OPPORTUNITY"]);
const SAFE_REASONS = new Set([
  "explicit_handoff_accepted",
  "accepted_provider_reconciliation_pending",
  "provider_rejection_recorded",
  "permanent_request_rejection",
  "delivery_auth_incident",
  "delivery_preflight_or_eligibility_review",
  "handoff_rate_limited",
  "edge_or_provider_unavailable",
  "handoff_not_confirmed",
  "handoff_transport_ambiguous",
  "delivery_subworkflow_failed",
  "lease_finish_unconfirmed",
]);

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
  finishClaim,
  workerId,
  limits = {},
}) {
  if (typeof rpc !== "function" || typeof handoff !== "function" || typeof finishClaim !== "function" ||
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
  if (!Array.isArray(claim.items) || claim.items.length > claimLimit) throw new Error("v2_claim_items_invalid");
  if (!Number.isInteger(claim.claimed) || claim.claimed !== claim.items.length) throw new Error("v2_claim_count_mismatch");

  // Validate the complete batch before any handoff or lease mutation. A malformed
  // later item must not cause a partially processed batch.
  const seenWork = new Set();
  const seenLeaseIds = new Set();
  const validatedItems = claim.items.map(item => {
    const workKey = `${String(item?.work_type ?? "")}:${String(item?.work_id ?? "")}`;
    if (seenWork.has(workKey)) throw new Error("v2_duplicate_claim_item");
    seenWork.add(workKey);
    if (!WORK_TYPES.has(item?.work_type) || !UUID.test(item?.work_id ?? "") || !UUID.test(item?.lease_id ?? "")) {
      throw new Error("v2_claim_item_invalid");
    }
    if (seenLeaseIds.has(item.lease_id)) throw new Error("v2_duplicate_lease_id");
    seenLeaseIds.add(item.lease_id);
    return {
      work_type: item.work_type,
      work_id: item.work_id,
      lease_id: item.lease_id,
    };
  });

  const summary = {
    worker_id: workerId,
    claimed: validatedItems.length,
    handoff_accepted: 0,
    terminal: 0,
    deferred: 0,
    lease_finish_unconfirmed: 0,
    outcomes: [],
  };

  for (const item of validatedItems) {
    // Project an explicit allowlist even though the SQL claim RPC now returns only
    // three opaque fields. This prevents future claim metadata from reaching the handoff.
    const safeClaim = {
      work_type: item?.work_type,
      work_id: item?.work_id,
      lease_id: item?.lease_id,
      worker_id: workerId,
      correlation_id: `v2:${String(item?.work_id ?? "")}`,
    };
    let result;
    try {
      result = await handoff(safeClaim);
    } catch {
      // An Execute Workflow timeout/failure may occur after the Edge Function
      // crossed the provider boundary. Defer safely and never expose raw errors.
      result = {
        work_type: safeClaim.work_type,
        work_id: safeClaim.work_id,
        outcome: "DEFERRED",
        reason: "delivery_subworkflow_failed",
        http_status: null,
        retry_after_seconds: 3600,
      };
    }
    // A subworkflow must return the same opaque work identity it received.
    // A mismatched or missing identity cannot complete this lease as accepted.
    if (result?.work_type !== safeClaim.work_type || result?.work_id !== safeClaim.work_id) {
      result = {
        outcome: "DEFERRED",
        reason: "delivery_subworkflow_failed",
        http_status: null,
        retry_after_seconds: 3600,
      };
    }
    let outcome = result?.outcome;
    if (!["HANDOFF_ACCEPTED", "TERMINAL", "DEFERRED"].includes(outcome)) {
      result = {
        outcome: "DEFERRED",
        reason: "delivery_subworkflow_failed",
        http_status: null,
        retry_after_seconds: 3600,
      };
      outcome = "DEFERRED";
    }
    if (outcome === "HANDOFF_ACCEPTED") summary.handoff_accepted += 1;
    else if (outcome === "TERMINAL") summary.terminal += 1;
    else summary.deferred += 1;
    const retryCandidate = Number(result.retry_after_seconds ?? 3600);
    const retryAfterSeconds = outcome === "HANDOFF_ACCEPTED" || outcome === "TERMINAL"
      ? 0
      : Number.isInteger(retryCandidate) && retryCandidate >= 0 && retryCandidate <= 86400
        ? retryCandidate
        : 3600;
    // Recovery, not Delivery, owns the lease. Finish only after the synchronous
    // Delivery subworkflow has returned its sanitized outcome.
    let leaseFinished = false;
    try {
      const finished = await finishClaim({
        lease_id: item.lease_id,
        worker_id: workerId,
        outcome,
        retry_after_seconds: retryAfterSeconds,
      });
      leaseFinished = finished?.finished === true;
    } catch {
      // The RPC may have committed before its response was lost. Do not blindly
      // retry the finisher; continue the batch and report an unconfirmed lease.
      leaseFinished = false;
    }
    if (!leaseFinished) summary.lease_finish_unconfirmed += 1;
    summary.outcomes.push({
      work_type: safeClaim.work_type,
      work_id: safeClaim.work_id,
      outcome,
      reason_code: !leaseFinished ? "lease_finish_unconfirmed" : SAFE_REASONS.has(result.reason) ? result.reason : "unspecified",
      http_status: Number.isInteger(result.http_status) && result.http_status >= 100 && result.http_status <= 599 ? result.http_status : null,
      lease_finished: leaseFinished,
    });
  }

  const leaseFinishesConfirmed = summary.lease_finish_unconfirmed === 0;
  return Object.freeze({
    accepted: leaseFinishesConfirmed,
    status: leaseFinishesConfirmed ? "COMPLETED" : "LEASE_FINISH_UNCONFIRMED",
    worker_id: workerId,
    stages: Object.freeze(Object.fromEntries(
      Object.entries(stageResults).map(([key, value]) => [key, {
        accepted: value.accepted === true,
        count: Number(value.eligible_upserted ?? value.candidates_upserted ?? value.opportunities_created ?? value.interventions_created ?? value.upserted ?? value.promoted ?? value.created ?? 0) || 0,
      }])
    )),
    summary: Object.freeze(summary),
    delivery_authorized_by_orchestrator: false,
    provider_called_by_orchestrator: false,
    recipient_pii_returned: false,
  });
}

export { DEFAULTS as V2_RECOVERY_TICK_DEFAULTS };
