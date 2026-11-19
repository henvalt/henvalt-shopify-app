const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WORK_TYPES = Object.freeze({
  CHECKOUT_INTERVENTION: "henvalt-shopify-contact-delivery-v2",
  PIXEL_OPPORTUNITY: "henvalt-shopify-pixel-delivery-v2",
});
const ACCEPTED_STATUSES = new Set(["submitted", "accepted", "handed_off"]);
const AMBIGUOUS_STATUSES = new Set([
  "ambiguous_provider_submission",
  "provider_accepted_record_pending",
  "provider_outcome_requires_reconciliation",
]);

function safeCorrelationId(value) {
  if (typeof value !== "string" || value.length > 80 || !/^[A-Za-z0-9._:-]+$/.test(value)) {
    throw new TypeError("invalid_correlation_id");
  }
  return value;
}

export function validateClaim(claim) {
  if (!claim || typeof claim !== "object" || Array.isArray(claim)) {
    throw new TypeError("invalid_claim");
  }
  const endpoint = WORK_TYPES[claim.work_type];
  if (!endpoint || !UUID.test(claim.work_id ?? "") || !UUID.test(claim.lease_id ?? "")) {
    throw new TypeError("invalid_claim");
  }
  if (typeof claim.worker_id !== "string" || !/^[A-Za-z0-9._:-]{3,80}$/.test(claim.worker_id)) {
    throw new TypeError("invalid_claim");
  }
  const correlationId = safeCorrelationId(claim.correlation_id);
  return Object.freeze({
    endpoint,
    workType: claim.work_type,
    workId: claim.work_id,
    leaseId: claim.lease_id,
    workerId: claim.worker_id,
    correlationId,
  });
}

export function classifyHandoffResponse(status, body) {
  const payload = body && typeof body === "object" && !Array.isArray(body) ? body : {};
  const state = typeof payload.status === "string" ? payload.status : "";
  if (status >= 200 && status < 300 && payload.accepted === true && ACCEPTED_STATUSES.has(state)) {
    return Object.freeze({ outcome: "HANDOFF_ACCEPTED", reason: "explicit_handoff_accepted", retryAfterSeconds: 0 });
  }
  if (status >= 200 && status < 300 && (payload.accepted === true && AMBIGUOUS_STATUSES.has(state))) {
    return Object.freeze({ outcome: "DEFERRED", reason: "provider_reconciliation_required", retryAfterSeconds: 3600 });
  }
  if (status === 400 || status === 404 || status === 410 || status === 422) {
    return Object.freeze({ outcome: "TERMINAL", reason: "permanent_request_rejection", retryAfterSeconds: 0 });
  }
  // 401/403, 409, throttling, 5xx, malformed JSON and all unknown responses
  // are conservative deferrals. They never trigger a second provider submission.
  return Object.freeze({ outcome: "DEFERRED", reason: "handoff_not_confirmed", retryAfterSeconds: 3600 });
}

export function createV2HandoffAdapter({ supabaseUrl, bearerToken, fetchImpl = fetch, finishClaim }) {
  if (typeof supabaseUrl !== "string" || !/^https:\/\//i.test(supabaseUrl) ||
      typeof bearerToken !== "string" || bearerToken.length < 16 ||
      typeof fetchImpl !== "function" || typeof finishClaim !== "function") {
    throw new TypeError("invalid_adapter_configuration");
  }
  const base = supabaseUrl.replace(/\/+$/, "");
  return async function handoff(claim) {
    const valid = validateClaim(claim);
    const body = valid.workType === "CHECKOUT_INTERVENTION"
      ? { intervention_id: valid.workId }
      : { opportunity_id: valid.workId };
    let classification;
    try {
      const response = await fetchImpl(`${base}/functions/v1/${valid.endpoint}`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${bearerToken}`,
          "content-type": "application/json",
          "x-henvalt-correlation-id": valid.correlationId,
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20000),
      });
      let parsed = null;
      try { parsed = await response.json(); } catch { /* malformed response is ambiguous */ }
      classification = classifyHandoffResponse(response.status, parsed);
    } catch {
      classification = Object.freeze({
        outcome: "DEFERRED",
        reason: "handoff_transport_ambiguous",
        retryAfterSeconds: 3600,
      });
    }
    const finished = await finishClaim({
      lease_id: valid.leaseId,
      worker_id: valid.workerId,
      outcome: classification.outcome,
      retry_after_seconds: classification.retryAfterSeconds,
    });
    // Deliberately return identifiers/outcome only. Never return provider bodies,
    // request headers, bearer tokens, customer data or raw exception messages.
    return Object.freeze({
      work_type: valid.workType,
      work_id: valid.workId,
      correlation_id: valid.correlationId,
      outcome: classification.outcome,
      reason: classification.reason,
      lease_finished: finished?.finished === true,
    });
  };
}
