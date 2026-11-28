const STAGING_SUPABASE_URL = "https://xidhtmrfvsgfmyltjuja.supabase.co";
const WORKER_ID = "henvalt_delivery_dispatcher_v1";

const json = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
});

function equalSecret(a, b) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function isUuid(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function validEmail(value) {
  return typeof value === "string" && value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function senderName(settings, identityMetadata) {
  const compliance = settings?.messaging_compliance || {};
  const profile = compliance.sender_profile || {};
  const suggestion = compliance.sender_profile_suggestion || {};
  const confirmed = profile.merchant_confirmed === true;
  const legalName = confirmed ? profile.legal_business_name : null;
  const candidate = legalName || suggestion.shop_name || identityMetadata?.from_name || "HENVALT";
  return String(candidate).trim().slice(0, 120) || "HENVALT";
}

export function createDeliveryDispatcherHandler({
  supabaseUrl,
  serviceRoleKey,
  fetchImpl = fetch,
  now = () => Date.now(),
}) {
  const configured = supabaseUrl === STAGING_SUPABASE_URL && !!serviceRoleKey;

  async function rest(path, options = {}) {
    return fetchImpl(supabaseUrl + path, {
      redirect: "error",
      ...options,
      headers: {
        apikey: serviceRoleKey,
        authorization: "Bearer " + serviceRoleKey,
        accept: "application/json",
        ...(options.headers || {}),
      },
    });
  }

  async function rpc(name, args) {
    const response = await rest("/rest/v1/rpc/" + name, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify(args),
    });
    if (!response.ok) throw new Error("rpc_" + name + "_failed");
    return response.json();
  }

  return async (request) => {
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
    if (!configured) return json(503, { error: "staging_dispatcher_not_configured" });
    const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!equalSecret(bearer, serviceRoleKey)) return json(401, { error: "service_role_required" });

    try {
      const controlResponse = await rest(
        "/rest/v1/provider_send_control?control_key=eq.global&select=provider_sending_enabled&limit=1",
        { headers: { "accept-profile": "henvalt" } },
      );
      if (!controlResponse.ok) return json(503, { state: "BLOCKED", reason: "provider_control_unavailable" });
      const controls = await controlResponse.json();
      if (!Array.isArray(controls) || controls[0]?.provider_sending_enabled !== true) {
        return json(200, { state: "PAUSED", reason: "provider_sending_disabled" });
      }

      const due = new Date(now()).toISOString();
      const requestResponse = await rest(
        "/rest/v1/delivery_requests?status=eq.PENDING&channel=eq.EMAIL&provider=eq.MAILERSEND&scheduled_at=lte." +
        encodeURIComponent(due) + "&select=id,tenant_id,intervention_id,correlation_id,scheduled_at&order=created_at.asc&limit=1",
        { headers: { "accept-profile": "henvalt" } },
      );
      if (!requestResponse.ok) return json(503, { state: "BLOCKED", reason: "delivery_queue_unavailable" });
      const pending = await requestResponse.json();
      const delivery = Array.isArray(pending) ? pending[0] : null;
      if (!delivery) return json(200, { state: "IDLE", processed: 0 });
      if (!isUuid(delivery.id) || !isUuid(delivery.tenant_id) || !isUuid(delivery.intervention_id)) {
        return json(409, { state: "BLOCKED", reason: "invalid_delivery_identity" });
      }

      const contextRows = await rpc("get_intervention_delivery_context", {
        p_intervention_id: delivery.intervention_id,
      });
      const context = Array.isArray(contextRows) ? contextRows[0] : null;
      if (!context || context.tenant_id !== delivery.tenant_id ||
          context.intervention_id !== delivery.intervention_id ||
          context.channel !== "EMAIL" ||
          context.provider !== "MAILERSEND" ||
          !validEmail(context.message_recipient) ||
          !validEmail(context.sender_reference) ||
          !context.message_subject || !context.message_body) {
        return json(409, { state: "BLOCKED", reason: "delivery_context_invalid" });
      }

      const tenantResponse = await rest(
        "/rest/v1/tenants?id=eq." + encodeURIComponent(delivery.tenant_id) + "&select=settings&limit=1",
        { headers: { "accept-profile": "henvalt" } },
      );
      if (!tenantResponse.ok) return json(503, { state: "BLOCKED", reason: "tenant_settings_unavailable" });
      const tenants = await tenantResponse.json();
      const tenant = Array.isArray(tenants) ? tenants[0] : null;
      if (!tenant) return json(409, { state: "BLOCKED", reason: "tenant_not_found" });

      const identityResponse = await rest(
        "/rest/v1/sending_identities?tenant_id=eq." + encodeURIComponent(delivery.tenant_id) +
        "&channel=eq.EMAIL&delivery_mode=eq." + encodeURIComponent(context.delivery_mode) +
        "&active=eq.true&select=metadata,sender_reference&order=created_at.desc&limit=1",
        { headers: { "accept-profile": "henvalt" } },
      );
      if (!identityResponse.ok) return json(503, { state: "BLOCKED", reason: "sender_identity_unavailable" });
      const identities = await identityResponse.json();
      const identity = Array.isArray(identities) ? identities[0] : null;
      if (!identity || identity.sender_reference?.toLowerCase() !== context.sender_reference.toLowerCase()) {
        return json(409, { state: "BLOCKED", reason: "sender_identity_mismatch" });
      }

      const fromName = senderName(tenant.settings, identity.metadata);
      const candidateReplyTo = identity.metadata?.reply_to;
      const replyTo = validEmail(candidateReplyTo) ? candidateReplyTo : context.sender_reference;

      const htmlBody = await rpc("render_sender_identity_footer", {
        p_tenant_id: delivery.tenant_id,
        p_html: context.message_body,
      });
      if (typeof htmlBody !== "string" || !htmlBody.trim()) {
        return json(409, { state: "BLOCKED", reason: "sender_footer_render_failed" });
      }
      const textBody = await rpc("render_email_plain_text", { p_html: htmlBody });
      if (typeof textBody !== "string" || !textBody.trim()) {
        return json(409, { state: "BLOCKED", reason: "plain_text_render_failed" });
      }

      const deliveryResponse = await rest("/functions/v1/henvalt-mailersend-delivery", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          tenant_id: delivery.tenant_id,
          delivery_request_id: delivery.id,
          intervention_id: delivery.intervention_id,
          correlation_id: delivery.correlation_id,
          to: context.message_recipient,
          from_email: context.sender_reference,
          from_name: fromName,
          reply_to: replyTo,
          subject: context.message_subject,
          html_body: htmlBody,
          text_body: textBody,
        }),
      });
      const providerBody = await deliveryResponse.json().catch(() => ({}));
      const stage = providerBody?.henvalt_delivery_stage || null;
      const providerMessageId = deliveryResponse.headers.get("x-message-id") || providerBody?.message_id || null;

      if (stage === "pre_provider") {
        const error = String(providerBody?.error || "delivery_preflight_rejected");
        if (error === "tenant_provider_credential_unavailable" || error === "delivery_service_not_configured") {
          return json(200, { state: "BLOCKED", reason: error, delivery_request_id: delivery.id });
        }
        const attemptId = await rpc("record_delivery_result", {
          p_delivery_request_id: delivery.id,
          p_provider: "MAILERSEND",
          p_provider_message_id: null,
          p_provider_status_code: deliveryResponse.status,
          p_state: "REJECTED",
          p_error_class: error.toUpperCase().slice(0, 100),
          p_retryable: false,
          p_provider_response: { stage: "pre_provider", error },
        });
        return json(200, { state: "REJECTED", delivery_request_id: delivery.id, attempt_id: attemptId, reason: error });
      }
      if (providerBody?.error === "provider_transport_ambiguous") {
        const attemptId = await rpc("record_delivery_result", {
          p_delivery_request_id: delivery.id,
          p_provider: "MAILERSEND",
          p_provider_message_id: null,
          p_provider_status_code: deliveryResponse.status,
          p_state: "UNKNOWN",
          p_error_class: "PROVIDER_TRANSPORT_AMBIGUOUS",
          p_retryable: false,
          p_provider_response: { error: "provider_transport_ambiguous", egress_started: true },
        });
        return json(200, { state: "UNKNOWN", delivery_request_id: delivery.id, attempt_id: attemptId });
      }

      if (stage !== "provider_response") {
        return json(200, {
          state: "BLOCKED",
          reason: providerBody?.error || "delivery_response_unclassified",
          delivery_request_id: delivery.id,
        });
      }

      const accepted = deliveryResponse.status >= 200 && deliveryResponse.status < 300;
      const retryable = deliveryResponse.status === 429 || deliveryResponse.status >= 500;
      const state = accepted ? "ACCEPTED" : "FAILED";
      const attemptId = await rpc("record_delivery_result", {
        p_delivery_request_id: delivery.id,
        p_provider: "MAILERSEND",
        p_provider_message_id: typeof providerMessageId === "string" ? providerMessageId : null,
        p_provider_status_code: deliveryResponse.status,
        p_state: state,
        p_error_class: accepted ? null : "MAILERSEND_HTTP_" + deliveryResponse.status,
        p_retryable: accepted ? false : retryable,
        p_provider_response: {
          stage: "provider_response",
          status: deliveryResponse.status,
          message: typeof providerBody?.message === "string" ? providerBody.message.slice(0, 300) : null,
        },
      });
      return json(200, {
        state,
        delivery_request_id: delivery.id,
        attempt_id: attemptId,
        worker: WORKER_ID,
      });
    } catch {
      return json(503, { state: "BLOCKED", error: "delivery_dispatch_failed" });
    }
  };
}

export { STAGING_SUPABASE_URL, WORKER_ID };
