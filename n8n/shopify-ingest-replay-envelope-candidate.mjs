const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIVE_JOB_STATES = new Set(["CLAIMED", "RUNNING"]);

/**
 * Build the exact input envelope consumed by the existing HENVALT_INGEST
 * normalizer. Inputs must come from the lease-fenced loader plus the recovery
 * claim row; this helper never accepts an HTTP request or arbitrary payload.
 */
export function buildShopifyReplayEnvelope(claim, loaded, now = Date.now()) {
  const c = claim && typeof claim === "object" ? claim : {};
  const r = loaded && typeof loaded === "object" ? loaded : {};
  const errors = [];
  const isUuid = (value) => typeof value === "string" && UUID_RE.test(value);

  if (!isUuid(c.job_id) || c.job_id !== r.job_id) errors.push("JOB_ID_MISMATCH");
  if (typeof c.worker_id !== "string" || !c.worker_id.trim()) errors.push("WORKER_ID_MISSING");
  if (!isUuid(c.lease_id)) errors.push("LEASE_ID_INVALID");
  if (!isUuid(r.webhook_id)) errors.push("WEBHOOK_ID_INVALID");
  if (!isUuid(r.tenant_id)) errors.push("TENANT_ID_INVALID");
  if (typeof r.source_event_id !== "string" || !r.source_event_id.trim()) errors.push("DELIVERY_ID_MISSING");
  if (typeof r.topic !== "string" || !r.topic.trim()) errors.push("TOPIC_MISSING");
  if (!r.payload || typeof r.payload !== "object" || Array.isArray(r.payload)) errors.push("PAYLOAD_NOT_OBJECT");
  if (!r.metadata || r.metadata.ingress_hmac_verified !== true) errors.push("INGRESS_HMAC_NOT_ATTESTED");
  const shop = typeof r.metadata?.shop_domain === "string" ? r.metadata.shop_domain.trim().toLowerCase() : "";
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop)) errors.push("SHOP_DOMAIN_INVALID");
  if (r.metadata?.shopify_webhook_id !== r.source_event_id) errors.push("DELIVERY_ID_METADATA_MISMATCH");
  if (typeof r.lease_expires_at !== "string" || !Number.isFinite(Date.parse(r.lease_expires_at)) || Date.parse(r.lease_expires_at) <= now) {
    errors.push("LEASE_EXPIRED_OR_INVALID");
  }
  if (r.webhook_processed === true) errors.push("WEBHOOK_ALREADY_PROCESSED");
  if (r.processing_status && !["PROCESSING", "FAILED"].includes(String(r.processing_status).toUpperCase())) {
    errors.push("WEBHOOK_STATE_NOT_REPLAYABLE");
  }
  if (r.correlation_id != null && !isUuid(r.correlation_id)) errors.push("CORRELATION_ID_INVALID");

  if (errors.length) return { ok: false, reason: errors.join(","), envelope: null };

  // Never mutate the stored JSON object; only add the canonical delivery ID.
  const body = { ...r.payload, event_id: r.source_event_id };
  if (r.correlation_id) body.correlation_id = r.correlation_id;
  else delete body.correlation_id;
  const headers = {
    "x-shopify-shop-domain": shop,
    "x-shopify-topic": r.topic,
    "x-shopify-webhook-id": r.source_event_id,
  };
  if (typeof r.metadata.shopify_api_version === "string") {
    headers["x-shopify-api-version"] = r.metadata.shopify_api_version;
  }
  if (typeof r.metadata.shopify_triggered_at === "string") {
    headers["x-shopify-triggered-at"] = r.metadata.shopify_triggered_at;
  }

  return {
    ok: true,
    reason: null,
    envelope: {
      body,
      headers,
      query: {},
      // This object is created only after the lease-fenced DB loader. The
      // public webhook body is nested under body and cannot populate it.
      replay_context: {
        job_id: c.job_id,
        worker_id: c.worker_id.trim(),
        lease_id: c.lease_id,
        lease_expires_at: r.lease_expires_at,
        tenant_id: r.tenant_id,
        webhook_id: r.webhook_id,
        correlation_id: r.correlation_id || null,
        source_event_id: r.source_event_id,
        ingress_hmac_verified: true,
      },
    },
  };
}
