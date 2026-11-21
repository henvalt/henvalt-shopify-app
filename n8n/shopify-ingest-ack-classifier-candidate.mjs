const ACTIVE_JOB_STATES = new Set(["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Classify receive_shopify_webhook_v1's explicit RPC row into one HTTP reply.
 * Never infer durable acceptance from HTTP 409 or from a missing job identifier.
 */
export function classifyShopifyIngressAck(input) {
  const raw = Array.isArray(input) ? input[0] : input;
  const row = raw && typeof raw === "object" ? raw : {};
  const fail = (status, result, message) => ({
    ok: false, terminate_ingress: true, http_status: status,
    body: { status: result, message },
  });

  const status = Number(row.http_status);
  const result = String(row.result_status || "");
  if (![200, 401, 404, 422, 503].includes(status)) {
    return fail(503, "temporarily_unavailable", "Ingress returned an invalid acknowledgement.");
  }
  if (status === 401) return fail(401, "unauthorized", "Webhook authentication failed.");
  if (status === 404) return fail(404, "unknown_tenant", "No active Shopify integration was found.");
  if (status === 422) return fail(422, "malformed_event", "Webhook payload or required headers were invalid.");
  if (status === 503) return fail(503, "temporarily_unavailable", "Durable webhook acceptance is unavailable.");

  if (!UUID_RE.test(String(row.webhook_id || ""))) {
    return fail(503, "temporarily_unavailable", "Ingress did not confirm a durable webhook record.");
  }
  if (result === "duplicate") {
    if (String(row.processing_status || "").toUpperCase() !== "PROCESSED") {
      return fail(503, "temporarily_unavailable", "Duplicate response was not backed by a processed webhook.");
    }
    return {
      ok: true, terminate_ingress: true, http_status: 200,
      body: { status: "duplicate", webhook_id: row.webhook_id },
    };
  }
  if (result === "accepted" || result === "replay_accepted") {
    const jobStatus = String(row.replay_job_status || "").toUpperCase();
    if (!UUID_RE.test(String(row.replay_job_id || "")) || !ACTIVE_JOB_STATES.has(jobStatus)) {
      return fail(503, "temporarily_unavailable", "Durable replay job was not confirmed active.");
    }
    return {
      ok: true, terminate_ingress: true, http_status: 200,
      body: {
        status: result, webhook_id: row.webhook_id,
        replay_job_id: row.replay_job_id, replay_job_status: jobStatus,
      },
    };
  }
  return fail(503, "temporarily_unavailable", "Ingress returned an unknown result state.");
}
