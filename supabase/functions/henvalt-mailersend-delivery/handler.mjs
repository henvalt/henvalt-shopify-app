const json = (status, body, extra = {}) => new Response(JSON.stringify(body), {
  status,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...extra,
  },
});

function preProviderJson(status, error) {
  return json(status, { error, henvalt_delivery_stage: "pre_provider" });
}

function constantTimeEqual(a, b) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function validEmail(value) {
  return typeof value === "string" &&
    value.length <= 254 &&
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function isUuid(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

export function createDeliveryHandler({ supabaseUrl, serviceRoleKey, fetchImpl = fetch }) {
  return async (req) => {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "authorization, apikey, content-type",
          "access-control-allow-methods": "POST, OPTIONS",
          "cache-control": "no-store",
        },
      });
    }
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
    if (!supabaseUrl || !serviceRoleKey) return preProviderJson(503, "delivery_service_not_configured");

    const authorization = req.headers.get("authorization") ?? "";
    const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!constantTimeEqual(bearer, serviceRoleKey)) return preProviderJson(401, "service_role_required");

    let apiToken = "";
    let providerEgressStarted = false;
    try {
      const body = await req.json().catch(() => ({}));
      const tenantId = body.tenant_id;
      const deliveryRequestId = body.delivery_request_id;
      const recipient = body.to;
      const sender = body.from_email;
      const fromName = body.from_name;
      const subject = body.subject;
      const html = body.html_body;
      const textBody = body.text_body;
      const replyTo = body.reply_to;

      if (!isUuid(tenantId) || !isUuid(deliveryRequestId)) return preProviderJson(400, "invalid_delivery_identity");
      if (!validEmail(recipient) || !validEmail(sender) || (replyTo != null && replyTo !== "" && !validEmail(replyTo))) {
        return preProviderJson(400, "invalid_email_address");
      }
      if (typeof fromName !== "string" || fromName.trim().length < 1 || fromName.length > 120 ||
          typeof subject !== "string" || subject.trim().length < 1 || subject.length > 200) {
        return preProviderJson(400, "invalid_message_headers");
      }
      if ((typeof html !== "string" || html.length < 1 || html.length > 100000) &&
          (typeof textBody !== "string" || textBody.length < 1 || textBody.length > 20000)) {
        return preProviderJson(400, "message_content_required");
      }

      const retryDelivery = body.delivery_generation_retry === true ||
        (body.metadata && body.metadata.delivery_generation_retry === true);
      const retryJobId = body.retry_job_id;
      const retryWorkerId = body.retry_worker_id;
      const retryGenerationNumber = Number(body.retry_generation_number);
      const retryIdentityPresent = retryJobId != null || retryWorkerId != null || body.retry_generation_number != null;
      if (retryDelivery && (!isUuid(retryJobId) ||
          typeof retryWorkerId !== "string" || retryWorkerId.trim().length < 1 || retryWorkerId.length > 120 ||
          !Number.isInteger(retryGenerationNumber) || ![2, 3].includes(retryGenerationNumber))) {
        return preProviderJson(400, "delivery_retry_identity_invalid");
      }
      if (!retryDelivery && retryIdentityPresent) {
        return preProviderJson(400, "delivery_retry_identity_invalid");
      }

      // Refresh and validate the exact retry-job lease before the credential
      // RPC can claim the delivery request. The final egress RPC repeats this
      // check under the same parent -> request -> job lock order.
      if (retryDelivery) {
        const leaseResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/renew_delivery_retry_job_lease", {
          method: "POST",
          redirect: "error",
          headers: {
            apikey: serviceRoleKey,
            authorization: "Bearer " + serviceRoleKey,
            "content-type": "application/json",
            accept: "application/json",
            "accept-profile": "henvalt",
            "content-profile": "henvalt",
          },
          body: JSON.stringify({
            p_tenant_id: tenantId,
            p_delivery_request_id: deliveryRequestId,
            p_retry_job_id: retryJobId,
            p_retry_worker_id: retryWorkerId,
            p_generation_number: retryGenerationNumber,
          }),
        });
        if (!leaseResponse.ok) return preProviderJson(409, "delivery_retry_job_claim_invalid");
        const leaseRenewed = await leaseResponse.json().catch(() => false);
        if (leaseRenewed !== true) return preProviderJson(409, "delivery_retry_job_claim_invalid");
      }

      // This RPC is the credential-release boundary. A closed/missing
      // database interlock must reject before any provider network call.
      const tokenResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/get_mailersend_token_for_delivery", {
        method: "POST",
        redirect: "error",
        headers: {
          apikey: serviceRoleKey,
          authorization: "Bearer " + serviceRoleKey,
          "content-type": "application/json",
          accept: "application/json",
          "accept-profile": "henvalt",
          "content-profile": "henvalt",
        },
        body: JSON.stringify({ p_tenant_id: tenantId, p_delivery_request_id: deliveryRequestId }),
      });
      if (!tokenResponse.ok) return preProviderJson(409, "tenant_provider_credential_unavailable");

      const tokenValue = await tokenResponse.json().catch(() => null);
      if (typeof tokenValue !== "string" || tokenValue.length < 20 || tokenValue.length > 512) {
        return preProviderJson(409, "tenant_provider_credential_unavailable");
      }
      apiToken = tokenValue;

      // The credential RPC authorizes and claims a delivery request, but the
      // caller-supplied HTTP body is not itself an authorization source. Bind
      // the destination and sender headers back to the claimed tenant record
      // before allowing any provider egress.
      const envelopeResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/assert_mailersend_delivery_envelope", {
        method: "POST",
        redirect: "error",
        headers: {
          apikey: serviceRoleKey,
          authorization: "Bearer " + serviceRoleKey,
          "content-type": "application/json",
          accept: "application/json",
          "accept-profile": "henvalt",
          "content-profile": "henvalt",
        },
        body: JSON.stringify({
          p_tenant_id: tenantId,
          p_delivery_request_id: deliveryRequestId,
          p_to: recipient,
          p_from_email: sender,
          p_from_name: fromName,
          p_reply_to: validEmail(replyTo) ? replyTo : sender,
          p_subject: subject,
          p_html_body: typeof html === "string" ? html : null,
          p_text_body: typeof textBody === "string" ? textBody : null,
        }),
      });
      if (!envelopeResponse.ok) return preProviderJson(409, "delivery_envelope_not_authorized");
      const envelopeAuthorized = await envelopeResponse.json().catch(() => false);
      if (envelopeAuthorized !== true) return preProviderJson(409, "delivery_envelope_not_authorized");

      const tags = ["tenant:" + tenantId, "delivery:" + deliveryRequestId];
      if (isUuid(body.intervention_id)) tags.push("intervention:" + body.intervention_id);
      if (isUuid(body.correlation_id)) tags.push("correlation:" + body.correlation_id);
      const message = {
        from: { email: sender, name: fromName },
        to: [{ email: recipient }],
        reply_to: { email: validEmail(replyTo) ? replyTo : sender },
        subject,
        tags,
      };
      if (typeof html === "string" && html.length > 0) message.html = html;
      if (typeof textBody === "string" && textBody.length > 0) message.text = textBody;

      // Commit the durable, one-way generation fence after all database
      // envelope checks and immediately before the provider HTTP request.
      // A failed/ambiguous fence call must never fall through to MailerSend.
      const egressFenceBody = retryDelivery
        ? {
            p_tenant_id: tenantId,
            p_delivery_request_id: deliveryRequestId,
            p_retry_job_id: retryJobId,
            p_retry_worker_id: retryWorkerId,
            p_generation_number: retryGenerationNumber,
          }
        : {
            p_tenant_id: tenantId,
            p_delivery_request_id: deliveryRequestId,
          };
      const egressFenceResponse = await fetchImpl(supabaseUrl + "/rest/v1/rpc/mark_mailersend_provider_egress_started", {
        method: "POST",
        redirect: "error",
        headers: {
          apikey: serviceRoleKey,
          authorization: "Bearer " + serviceRoleKey,
          "content-type": "application/json",
          accept: "application/json",
          "accept-profile": "henvalt",
          "content-profile": "henvalt",
        },
        body: JSON.stringify(egressFenceBody),
      });
      if (!egressFenceResponse.ok) return preProviderJson(409, "delivery_provider_egress_fence_rejected");
      const egressFenceStarted = await egressFenceResponse.json().catch(() => false);
      if (egressFenceStarted !== true) return preProviderJson(409, "delivery_provider_egress_fence_rejected");

      let providerResponse;
      try {
        providerEgressStarted = true;
        providerResponse = await fetchImpl("https://api.mailersend.com/v1/email", {
          method: "POST",
          redirect: "error",
          headers: {
            authorization: "Bearer " + apiToken,
            "content-type": "application/json",
            "x-requested-with": "XMLHttpRequest",
          },
          body: JSON.stringify(message),
        });
      } catch {
        return json(502, { error: "provider_transport_ambiguous" });
      }

      const raw = await providerResponse.text().catch(() => "");
      let providerBody = {};
      if (raw) {
        try { providerBody = JSON.parse(raw); }
        catch { providerBody = { message: raw.slice(0, 1000) }; }
      }
      const responseHeaders = {};
      const messageId = providerResponse.headers.get("x-message-id");
      if (messageId) responseHeaders["x-message-id"] = messageId;
      // Never trust a provider response to assert HENVALT's internal stage.
      // Override any provider-supplied value so only our own preflight branches
      // can produce the exact "pre_provider" marker used by quota settlement.
      const normalizedProviderBody = providerBody && typeof providerBody === "object"
        ? { ...providerBody, henvalt_delivery_stage: "provider_response" }
        : { result: providerBody, henvalt_delivery_stage: "provider_response" };
      return json(providerResponse.status, normalizedProviderBody, responseHeaders);
    } catch {
      return providerEgressStarted
        ? json(500, { error: "delivery_provider_failed" })
        : preProviderJson(500, "delivery_preflight_failed");
    } finally {
      apiToken = "";
    }
  };
}
