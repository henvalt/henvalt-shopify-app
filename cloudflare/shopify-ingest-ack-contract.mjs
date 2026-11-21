export const SHOPIFY_INGEST_ACK_CONTRACT = Object.freeze({
  webhookResponseMode: "responseNode",
  respondNode: "Acknowledge Durable Ingest",
  afterNode: "Classify Result",
  beforeNode: "Should Process?",
  responseCodeExpression: "={{ $json.__http }}",
  responseBodyExpression: "={{ $json.__body }}",
  continueExecutionAfterResponse: true,
  acknowledgeOnlyAfter: "ingest_raw_webhook_v2",
  acceptedStatuses: Object.freeze([200]),
  retryableStatuses: Object.freeze([503]),
  rejectStatuses: Object.freeze([401, 404, 422]),
});
