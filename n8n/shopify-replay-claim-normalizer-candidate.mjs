const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parsePayload(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value !== "string") return null;
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

/**
 * Normalize the SETOF henvalt.background_jobs row returned by
 * claim_shopify_replay_job. Only the trusted lease tuple and webhook UUID
 * leave this function; the raw payload is never forwarded.
 */
export function normalizeShopifyReplayClaim(row, workerId) {
  const raw = row && typeof row === "object" && !Array.isArray(row) ? row : {};
  const rowPresent = raw.id !== null && raw.id !== undefined;

  if (!rowPresent) {
    return {
      claim_row_present: false,
      guard_valid: false,
      has_replay_job: false,
      guard_reason: "EMPTY_CLAIM",
    };
  }

  const payload = parsePayload(raw.payload);
  const normalizedWorkerId = typeof workerId === "string" ? workerId.trim() : "";
  const jobId = raw.id;
  const leaseId = raw.lease_id;
  const webhookId = payload && payload.webhook_id;
  const expiry = raw.lease_expires_at;
  const errors = [];

  if (raw.job_type !== "process_shopify_webhook") errors.push("UNEXPECTED_JOB_TYPE");
  if (typeof jobId !== "string" || !UUID_RE.test(jobId)) errors.push("INVALID_JOB_ID");
  if (typeof leaseId !== "string" || !UUID_RE.test(leaseId)) errors.push("INVALID_LEASE_ID");
  if (!normalizedWorkerId) errors.push("MISSING_WORKER_ID");
  if (typeof webhookId !== "string" || !UUID_RE.test(webhookId)) errors.push("INVALID_WEBHOOK_ID");
  if (typeof expiry !== "string" || !Number.isFinite(Date.parse(expiry))) {
    errors.push("INVALID_LEASE_EXPIRY");
  }

  if (errors.length) {
    return {
      claim_row_present: true,
      guard_valid: false,
      has_replay_job: false,
      guard_reason: errors.join(","),
    };
  }

  return {
    claim_row_present: true,
    guard_valid: true,
    has_replay_job: true,
    job_id: jobId,
    worker_id: normalizedWorkerId,
    lease_id: leaseId,
    lease_expires_at: expiry,
    webhook_id: webhookId,
  };
}
