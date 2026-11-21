const resp = $json || {};
const norm = $("Validate & Normalize").item.json;
const corr = norm.correlation_id;
const eventId = norm.event.event_id;

if (resp.error !== undefined || resp.statusCode === undefined) {
  return {
    __proceed: false,
    __http: 503,
    __body: { status: "temporarily_unavailable", message: "Processing backend unavailable; retry.", correlation_id: corr },
  };
}

const code = resp.statusCode;
const raw = resp.body;
const row = Array.isArray(raw) ? (raw[0] || {}) : (raw || {});

if (code >= 200 && code < 300) {
  if (!row.webhook_id || !row.processing_status) {
    return {
      __proceed: false,
      __http: 503,
      __body: { status: "temporarily_unavailable", message: "Durable ingest returned an incomplete result.", correlation_id: corr },
    };
  }

  const processingStatus = String(row.processing_status).toUpperCase();
  if (processingStatus === "PROCESSED") {
    return {
      __proceed: false,
      __webhook_id: row.webhook_id,
      __http: 200,
      __body: { status: "duplicate", event_id: eventId, webhook_id: row.webhook_id, processing_status: processingStatus, correlation_id: corr },
    };
  }

  const replayJobStatus = String(row.replay_job_status || "").toUpperCase();
  const replayJobIsDurable = !!row.replay_job_id &&
    ["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"].includes(replayJobStatus);

  if (!replayJobIsDurable) {
    return {
      __proceed: false,
      __webhook_id: row.webhook_id,
      __http: 503,
      __body: { status: "temporarily_unavailable", message: "Webhook row has no active durable replay job.", correlation_id: corr },
    };
  }

  if (row.should_process === false) {
    return {
      __proceed: false,
      __webhook_id: row.webhook_id,
      __replay_job_id: row.replay_job_id,
      __http: 200,
      __body: { status: "already_processing", event_id: eventId, webhook_id: row.webhook_id, replay_job_id: row.replay_job_id, correlation_id: corr },
    };
  }

  if (row.should_process === true) {
    return {
      __proceed: true,
      __webhook_id: row.webhook_id,
      __replay_job_id: row.replay_job_id,
      __http: 200,
      __body: {
        status: row.is_duplicate === true ? "replay_accepted" : "accepted",
        event_id: eventId,
        webhook_id: row.webhook_id,
        replay_job_id: row.replay_job_id,
        replayed: row.is_duplicate === true,
        correlation_id: corr,
      },
    };
  }

  return {
    __proceed: false,
    __webhook_id: row.webhook_id,
    __http: 503,
    __body: { status: "temporarily_unavailable", message: "Ingest RPC omitted processing decision.", correlation_id: corr },
  };
}

// Never turn a generic conflict into an unconditional success. Only a durable row
// plus a verified, active replay job can justify a 2xx response.
if (code === 409) {
  return {
    __proceed: false,
    __http: 503,
    __body: { status: "temporarily_unavailable", message: "Webhook conflict could not be tied to a durable replay job.", correlation_id: corr },
  };
}
if (code === 401 || code === 403) {
  return { __proceed: false, __http: 401, __body: { status: "unauthorized", message: "Webhook signature or service authorization failed.", correlation_id: corr } };
}
if (code === 404) {
  return { __proceed: false, __http: 404, __body: { status: "unknown_tenant", message: "No active integration matches this shop.", correlation_id: corr } };
}
if (code >= 400 && code < 500) {
  return { __proceed: false, __http: 422, __body: { status: "rejected", message: "Event was not accepted by business rules.", correlation_id: corr } };
}
return {
  __proceed: false,
  __http: 503,
  __body: { status: "temporarily_unavailable", message: "Processing backend error; retry.", correlation_id: corr },
};
