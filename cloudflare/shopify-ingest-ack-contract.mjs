export const SHOPIFY_INGEST_ACK_CONTRACT = Object.freeze({
  webhookResponseMode: "responseNode",
  respondNode: "Acknowledge Ingress Request",
  successEnvelopeNode: "Classify Result",
  rejectionEnvelopeNode: "Build Rejection Response",
  successResponseAfterNode: "Classify Result",
  successResponseBeforeNode: "Webhook execution ends after acknowledgement",
  preIngestFailureRoutes: Object.freeze([
    "HMAC Verified? false",
    "Is Valid false",
  ]),
  responseCodeExpression: "={{ $json.__http }}",
  responseBodyExpression: "={{ $json.__body }}",
  continueExecutionAfterResponse: false,
  acceptedIngestRequires: Object.freeze([
    "ingest_raw_webhook_v2 returned HTTP 2xx",
    "webhook_id is present",
    "should_process is an explicit boolean",
    "replay_job_id and active replay_job_status are present for unprocessed events",
  ]),
  replayQueue: Object.freeze({
    jobType: "process_shopify_webhook",
    workerWorkflow: "HENVALT_RECOVERY",
    processorWorkflow: "HENVALT_INGEST",
    atomicWithWebhookInsert: true,
  }),
  conflictHandling: Object.freeze({
    generic409WithoutWebhookId: 503,
    requireDurableWebhookIdForDuplicate200: true,
    requireExplicitProcessingDecision: true,
  }),
  preIngestFailureStatuses: Object.freeze({
    invalidHmac: 401,
    unknownTenant: 404,
    malformedEvent: 422,
    tenantLookupUnavailable: 503,
  }),
  acceptedStatuses: Object.freeze([200]),
  retryableStatuses: Object.freeze([503]),
  rejectStatuses: Object.freeze([401, 404, 422]),
  duplicateStatuses: Object.freeze([200]),
});

const response = (http, body, proceed = false, webhookId = null) => ({
  http,
  body,
  proceed,
  webhookId,
});

const failure = (http, status, message, correlationId) =>
  response(http, { status, message, correlation_id: correlationId });

const activeReplayJob = (row) => {
  const jobId = row?.replay_job_id;
  const status = String(row?.replay_job_status || "").toUpperCase();
  return Boolean(jobId) && ["QUEUED", "CLAIMED", "RUNNING", "RETRY_WAIT"].includes(status);
};

export function classifyIngestResponse(input, context = {}) {
  const eventId = context.eventId ?? null;
  const correlationId = context.correlationId ?? null;
  const resp = input && typeof input === "object" ? input : {};

  if (resp.error !== undefined || !Number.isInteger(resp.statusCode)) {
    return failure(503, "temporarily_unavailable", "Ingest backend unavailable; retry.", correlationId);
  }

  const code = resp.statusCode;
  if (code >= 200 && code < 300) {
    const raw = resp.body;
    const row = Array.isArray(raw) ? raw[0] : raw;
    if (!row || typeof row !== "object" || !row.webhook_id) {
      return failure(503, "temporarily_unavailable", "Ingest returned no durable webhook ID.", correlationId);
    }
    if (typeof row.should_process !== "boolean") {
      return failure(503, "temporarily_unavailable", "Ingest omitted its processing decision.", correlationId);
    }

    const processingStatus = String(row.processing_status || "").toUpperCase();
    if (row.should_process === false) {
      if (processingStatus === "PROCESSED") {
        return response(
          200,
          {
            status: "duplicate",
            event_id: eventId,
            webhook_id: row.webhook_id,
            processing_status: processingStatus,
            correlation_id: correlationId,
          },
          false,
          row.webhook_id,
        );
      }
      if (processingStatus !== "PROCESSING" || !activeReplayJob(row)) {
        return failure(503, "temporarily_unavailable", "In-flight webhook has no verifiable active replay job.", correlationId);
      }
      return response(
        200,
        {
          status: "already_processing",
          event_id: eventId,
          webhook_id: row.webhook_id,
          replay_job_id: row.replay_job_id,
          replay_job_status: String(row.replay_job_status).toUpperCase(),
          processing_status: processingStatus,
          correlation_id: correlationId,
        },
        false,
        row.webhook_id,
      );
    }

    if (!activeReplayJob(row)) {
      return failure(503, "temporarily_unavailable", "Durable webhook replay job was not confirmed.", correlationId);
    }

    return response(
      200,
      {
        status: row.is_duplicate === true ? "replay_accepted" : "accepted",
        event_id: eventId,
        webhook_id: row.webhook_id,
        replay_job_id: row.replay_job_id,
        replay_job_status: String(row.replay_job_status).toUpperCase(),
        replayed: row.is_duplicate === true,
        correlation_id: correlationId,
      },
      true,
      row.webhook_id,
    );
  }

  if (code === 401 || code === 403) {
    return failure(401, "unauthorized", "Webhook authentication failed.", correlationId);
  }
  if (code === 404) {
    return failure(404, "unknown_tenant", "No active integration matches this shop.", correlationId);
  }
  if (code >= 400 && code < 500 && code !== 409) {
    return failure(422, "rejected", "Event was not accepted by validation rules.", correlationId);
  }

  // A generic 409 is not proof of a duplicate. The durable row and replay job
  // must be returned by the idempotent RPC before success can be acknowledged.
  return failure(503, "temporarily_unavailable", "Ingest conflict or backend failure; retry.", correlationId);
}

export function buildPreIngestRejection(kind, context = {}) {
  const correlationId = context.correlationId ?? null;
  switch (kind) {
    case "invalidHmac":
      return failure(401, "unauthorized", "Webhook authentication failed.", correlationId);
    case "unknownTenant":
      return failure(404, "unknown_tenant", "No active integration matches this shop.", correlationId);
    case "malformedEvent":
      return failure(422, "rejected", "Event is missing required fields.", correlationId);
    case "tenantLookupUnavailable":
      return failure(503, "temporarily_unavailable", "Tenant lookup unavailable; retry.", correlationId);
    default:
      return failure(503, "temporarily_unavailable", "Ingress validation unavailable; retry.", correlationId);
  }
}
