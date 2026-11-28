const STAGING_SUPABASE_URL = "https://xidhtmrfvsgfmyltjuja.supabase.co";
const DEFAULT_MODEL = "openai/gpt-oss-120b";
const WORKER_ID_PREFIX = "henvalt_recovery_executor:";
const MAX_PROMPT_CHARS = 16000;

const SYSTEM_PROMPT = [
  "You are the senior lifecycle copywriter for a respected ecommerce brand.",
  "Write one recovery email inside an already-approved recovery action. You do not decide eligibility, consent, attribution, or state.",
  "Write with empathy, warmth, restraint, and natural language. Never reveal tracking or say we watched the customer.",
  "Never invent product details, prices, discounts, shipping promises, stock, deadlines, scarcity, testimonials, or URLs.",
  "Use only supplied facts. Do not claim the customer opened or ignored earlier emails.",
  "Use a short human subject, one clear CTA, and concise body copy. No markdown links or URLs.",
  "Return strict JSON only with exactly these keys: subject, opening, body, cta_text."
].join(" ");

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

function isUuid(v) {
  return typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
}

function escapeHtml(value) {
  return String(value ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function safeColor(value, fallback) {
  return typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
}

function parseJsonContent(content) {
  if (typeof content !== "string" || content.length > 12000) return null;
  try {
    const parsed = JSON.parse(content);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const keys = Object.keys(parsed).sort().join(",");
    if (keys !== "body,cta_text,opening,subject") return null;
    if (typeof parsed.subject !== "string" || !parsed.subject.trim() || parsed.subject.length > 200) return null;
    if (typeof parsed.opening !== "string" || parsed.opening.length > 500) return null;
    if (typeof parsed.body !== "string" || !parsed.body.trim() || parsed.body.length > 5000) return null;
    if (typeof parsed.cta_text !== "string" || !parsed.cta_text.trim() || parsed.cta_text.length > 80) return null;
    const urlPattern = /https?:\/\/[^\s"'<>]+/i;
    if ([parsed.subject, parsed.opening, parsed.body, parsed.cta_text].some((s) => urlPattern.test(s))) return null;
    return parsed;
  } catch {
    return null;
  }
}

function buildEmail({ copy, context, trackingUrl, unsubscribeUrl }) {
  const store = escapeHtml(String(context.store_name || "Our store").slice(0, 100));
  const branding = context.email_branding && typeof context.email_branding === "object" ? context.email_branding : {};
  const primary = safeColor(branding.primary_color, "#171717");
  const background = safeColor(branding.background_color, "#f4f4f1");
  const accent = safeColor(branding.accent_color, "#77776f");
  const logo = typeof branding.logo_url === "string" && /^https:\/\//i.test(branding.logo_url)
    ? branding.logo_url : "";
  const brandHeader = logo
    ? '<img src="' + escapeHtml(logo) + '" alt="' + store + '" width="160" style="display:block;max-width:160px;max-height:48px;width:auto;height:auto;border:0">'
    : '<div style="font:700 20px Arial,Helvetica,sans-serif;color:' + primary + '">' + store + "</div>";
  const paragraphs = [copy.opening, copy.body].filter(Boolean).map((part) =>
    '<p style="margin:0 0 16px;font:16px/1.65 Arial,Helvetica,sans-serif;color:#292929">' +
      escapeHtml(part).replace(/\n/g, "<br>") + "</p>"
  ).join("");
  const cta = escapeHtml(copy.cta_text);
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' +
    escapeHtml(copy.subject) + '</title></head><body style="margin:0;padding:0;background:' + background + '">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:' + background + '"><tr><td align="center" style="padding:34px 14px">' +
    '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #e9e9e5;border-radius:16px">' +
    '<tr><td style="padding:27px 34px;border-bottom:1px solid #eee">' + brandHeader + '</td></tr>' +
    '<tr><td style="padding:34px">' + paragraphs +
    '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:26px 0 10px"><tr><td bgcolor="' + primary + '" style="border-radius:8px">' +
    '<a href="' + escapeHtml(trackingUrl) + '" style="display:inline-block;padding:15px 25px;font:700 14px Arial,Helvetica,sans-serif;color:#fff;text-decoration:none">' + cta + "</a>" +
    '</td></tr></table></td></tr><tr><td style="padding:22px 34px;background:#fafaf8;border-top:1px solid #eee">' +
    '<p style="margin:0 0 10px;font:13px/1.5 Arial,Helvetica,sans-serif;color:#555">If you have a question, simply reply to this email.</p>' +
    '<p style="margin:0 0 10px;font:11px/1.5 Arial,Helvetica,sans-serif;color:#999">You are receiving this because you opted in to hear from ' + store + '.</p>' +
    '<a href="' + escapeHtml(unsubscribeUrl) + '" style="font:11px Arial,Helvetica,sans-serif;color:' + accent + '">Unsubscribe from recovery emails</a>' +
    "</td></tr></table></td></tr></table></body></html>";
  const text = [String(context.store_name || "Our store"), "", copy.opening, copy.body, "",
    copy.cta_text + ": " + trackingUrl, "", "Unsubscribe: " + unsubscribeUrl].filter(Boolean).join("\n");
  return { html, text };
}

export function createRecoveryExecutorHandler({
  supabaseUrl,
  serviceRoleKey,
  publicActionsBaseUrl,
  fetchImpl = fetch,
  now = () => Date.now(),
  workerId = () => WORKER_ID_PREFIX + crypto.randomUUID(),
}) {
  const configured = supabaseUrl === STAGING_SUPABASE_URL && !!serviceRoleKey;
  const publicBase = (() => {
    try {
      const u = new URL(publicActionsBaseUrl || "");
      return u.protocol === "https:" ? u.toString().replace(/\/$/, "") : "";
    } catch { return ""; }
  })();

  async function rpc(name, args) {
    const response = await fetchImpl(supabaseUrl + "/rest/v1/rpc/" + name, {
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
      body: JSON.stringify(args),
    });
    if (!response.ok) throw new Error("rpc_" + name + "_failed");
    return response.json();
  }

  return async (request) => {
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
    if (!configured) return json(503, { error: "staging_executor_not_configured" });
    const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!equalSecret(bearer, serviceRoleKey)) return json(401, { error: "service_role_required" });

    let body;
    try {
      const raw = await request.text();
      if (raw.length > 2000) return json(413, { error: "request_too_large" });
      body = raw ? JSON.parse(raw) : {};
    } catch { return json(400, { error: "invalid_json" }); }
    if (body?.mode && body.mode !== "process_one") return json(400, { error: "unsupported_mode" });

    const id = workerId();
    let job = null;
    let interventionId = null;
    let claimed = false;
    let jobId = null;
    try {
      const claimedJobs = await rpc("claim_next_job", {
        p_worker_id: id,
        p_job_types: ["execute_intervention"],
      });
      job = Array.isArray(claimedJobs) ? claimedJobs[0] : null;
      if (!job) return json(200, { state: "IDLE", processed: 0 });
      jobId = job.id;
      let payload = job.payload ?? {};
      if (typeof payload === "string") {
        try { payload = JSON.parse(payload); } catch { payload = {}; }
      }
      interventionId = payload.intervention_id;
      if (!isUuid(jobId) || !isUuid(interventionId)) {
        await rpc("retry_job", { p_job_id: jobId, p_worker_id: id, p_error: "invalid_execute_intervention_payload", p_delay_seconds: 900 });
        return json(200, { state: "RETRY_SCHEDULED", reason: "invalid_job_payload" });
      }

      const claimRows = await rpc("claim_intervention_for_send", { p_intervention_id: interventionId });
      const claim = Array.isArray(claimRows) ? claimRows[0]?.claim_state : null;
      if (claim !== "CLAIMED") {
        if (["ALREADY_SENT", "NOT_SENDABLE"].includes(String(claim))) {
          await rpc("complete_job", { p_job_id: jobId, p_worker_id: id });
          return json(200, { state: "SKIPPED", reason: String(claim) });
        }
        await rpc("retry_job", { p_job_id: jobId, p_worker_id: id, p_error: "intervention_claim_" + String(claim || "unknown"), p_delay_seconds: 300 });
        return json(200, { state: "RETRY_SCHEDULED", reason: "intervention_not_claimed" });
      }
      claimed = true;

      const context = await rpc("get_recovery_worker_context", { p_intervention_id: interventionId });
      if (!context || context.context_found === false) {
        await rpc("resolve_intervention_send_failure", {
          p_intervention_id: interventionId,
          p_final_status: "SKIPPED",
          p_reason: "recovery_context_missing",
        });
        await rpc("complete_job", { p_job_id: jobId, p_worker_id: id });
        return json(200, { state: "SKIPPED", reason: "recovery_context_missing" });
      }
      const recoveryType = String(context.recovery_type || context.opportunity_type || "").toUpperCase();
      const delay = Number(context.flow_delay_minutes);
      const scheduledAt = context.scheduled_at ? Date.parse(context.scheduled_at) : now();
      const activityAt = context.checkout_updated_at ? Date.parse(context.checkout_updated_at) : NaN;
      const delayValid = Number.isInteger(delay) && delay >= 5 && delay <= 10080;
      const idleElapsed = ["PAYMENT_FAILURE", "PAYMENT_DECLINED"].includes(recoveryType)
        ? delayValid
        : delayValid && Number.isFinite(activityAt) && (now() - activityAt) >= delay * 60000;
      const destination = context.checkout_url || context.destination_url || null;
      let destinationValid = false;
      try { destinationValid = !!destination && new URL(destination).protocol === "https:"; } catch { destinationValid = false; }
      const checks = {
        tenant_active: context.tenant_active === true,
        shop_connection_active: context.shop_connection_active === true,
        sendable_status: ["SENDING", "READY", "SCHEDULED"].includes(String(context.intervention_status || "").toUpperCase()),
        recovery_active: context.recovery_active === true,
        opportunity_open: context.opportunity_open === true,
        not_recovered: context.order_recovered !== true,
        consent_valid: context.consent_valid === true,
        recipient: !!(context.recipient || context.message_recipient || context.recipient_reference),
        email_channel: String(context.channel || "").toUpperCase() === "EMAIL",
        sender: !!context.sender_reference,
        sender_configured: context.sender_configured === true,
        scheduled: Number.isFinite(scheduledAt) && scheduledAt <= now(),
        flow_delay_configured: delayValid,
        idle_window_elapsed: idleElapsed,
        no_suppression: context.suppression_exists === false,
        destination_url: destinationValid,
      };
      const failed = Object.keys(checks).filter((key) => !checks[key]);
      if (failed.length) {
        const retryable = failed.every((key) => ["sender", "sender_configured", "idle_window_elapsed"].includes(key));
        const finalStatus = retryable ? "READY" : "SKIPPED";
        await rpc("resolve_intervention_send_failure", {
          p_intervention_id: interventionId,
          p_final_status: finalStatus,
          p_reason: "PREFLIGHT_" + failed.join(","),
        });
        if (retryable) {
          await rpc("retry_job", {
            p_job_id: jobId, p_worker_id: id,
            p_error: "PREFLIGHT_" + failed.join(","), p_delay_seconds: 300,
          });
        } else {
          await rpc("complete_job", { p_job_id: jobId, p_worker_id: id });
        }
        return json(200, { state: retryable ? "RETRY_SCHEDULED" : "SKIPPED", failed_checks: failed });
      }

      if (!publicBase) {
        await rpc("resolve_intervention_send_failure", {
          p_intervention_id: interventionId,
          p_final_status: "READY",
          p_reason: "PUBLIC_ACTIONS_BASE_URL_NOT_CONFIGURED",
        });
        await rpc("retry_job", {
          p_job_id: jobId, p_worker_id: id,
          p_error: "PUBLIC_ACTIONS_BASE_URL_NOT_CONFIGURED", p_delay_seconds: 900,
        });
        return json(200, { state: "RETRY_SCHEDULED", reason: "public_actions_endpoint_not_configured" });
      }
      const prior = await fetchImpl(
        supabaseUrl + "/rest/v1/delivery_requests?intervention_id=eq." + encodeURIComponent(interventionId) + "&select=id&limit=1",
        { method: "GET", redirect: "error", headers: { apikey: serviceRoleKey, authorization: "Bearer " + serviceRoleKey, "accept-profile": "henvalt" } },
      );
      if (!prior.ok) throw new Error("delivery_request_lookup_failed");
      const priorRows = await prior.json();
      if (Array.isArray(priorRows) && priorRows.length) {
        await rpc("complete_job", { p_job_id: jobId, p_worker_id: id });
        return json(200, { state: "DELIVERY_REQUEST_ALREADY_EXISTS", delivery_request_id: priorRows[0].id });
      }

      const trackingRows = await rpc("create_tracking_token", {
        p_intervention_id: interventionId, p_destination_url: destination, p_ttl_seconds: 259200,
      });
      const tracking = Array.isArray(trackingRows) ? trackingRows[0] : null;
      if (!tracking?.token || !isUuid(tracking.tracking_token_id)) throw new Error("tracking_token_creation_failed");

      const unsubscribeRows = await rpc("create_unsubscribe_token", { p_intervention_id: interventionId });
      const unsubscribe = Array.isArray(unsubscribeRows) ? unsubscribeRows[0] : null;
      if (!unsubscribe?.token || !isUuid(unsubscribe.unsubscribe_token_id)) throw new Error("unsubscribe_token_creation_failed");

      const stepNumber = Math.max(1, Math.min(3, Number(context.step_number || 1)));
      const stepGuidance = stepNumber === 1
        ? "Reconnect warmly and make resuming effortless."
        : stepNumber === 2
          ? "Remove friction with a new angle; do not repeat previous wording."
          : "Leave the door open graciously, with no pressure.";
      const typeGuidance = recoveryType === "ABANDONED_CART"
        ? "This is a cart, not a checkout. Refer only to supplied cart items."
        : recoveryType === "BROWSE_ABANDONMENT"
          ? "This is a product page, not a cart or checkout."
          : ["PAYMENT_FAILURE", "PAYMENT_DECLINED"].includes(recoveryType)
            ? "Be calm about the payment not completing. Never infer a decline reason."
            : "Help the customer resume the existing checkout.";
      const limitedContext = {
        recovery_type: recoveryType,
        step_number: stepNumber,
        previous_messages: Array.isArray(context.previous_messages) ? context.previous_messages.slice(0, 2) : [],
        store_name: context.store_name || "Our store",
        customer_first_name: context.customer_first_name || null,
        products: Array.isArray(context.products) ? context.products.slice(0, 20) : [],
        cart_or_checkout_value: context.value_at_risk ?? null,
        currency: context.currency || null,
      };
      const prompt = [typeGuidance, stepGuidance, "Authoritative recovery facts (JSON): " + JSON.stringify(limitedContext)].join(" ");
      if (prompt.length > MAX_PROMPT_CHARS) throw new Error("ai_context_too_large");

      const aiResponse = await fetchImpl(supabaseUrl + "/functions/v1/henvalt-groq-generate", {
        method: "POST",
        redirect: "error",
        headers: {
          authorization: "Bearer " + serviceRoleKey,
          apikey: serviceRoleKey,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          model: DEFAULT_MODEL,
          temperature: 0.3,
          response_format: { type: "json_object" },
          messages: [{ role: "system", content: SYSTEM_PROMPT }, { role: "user", content: prompt }],
          stream: false,
        }),
        signal: AbortSignal.timeout(30000),
      });
      if (!aiResponse.ok) {
        await aiResponse.arrayBuffer().catch(() => new ArrayBuffer(0));
        throw new Error("ai_provider_request_failed");
      }
      const aiBody = await aiResponse.json();
      const copy = parseJsonContent(aiBody?.choices?.[0]?.message?.content);
      if (!copy) throw new Error("ai_output_invalid");

      const trackingUrl = publicBase + "/track/" + encodeURIComponent(tracking.token);
      const unsubscribeUrl = publicBase + "/unsubscribe/" + encodeURIComponent(unsubscribe.token);
      const rendered = buildEmail({ copy, context, trackingUrl, unsubscribeUrl });
      const messageId = await rpc("render_and_queue_message", {
        p_intervention_id: interventionId,
        p_recipient: context.recipient || context.message_recipient || context.recipient_reference,
        p_subject: copy.subject,
        p_body: rendered.html,
        p_tracking_token_id: tracking.tracking_token_id,
        p_metadata: {
          engine_version: "henvalt-recovery-executor-0.1.0",
          ai_provider: "GROQ",
          ai_model: DEFAULT_MODEL,
          prompt_version: "recovery.email.v2",
          policy_version: "v1",
          correlation_id: context.correlation_id || job.correlation_id || null,
          unsubscribe_url: unsubscribeUrl,
          unsubscribe_token_id: unsubscribe.unsubscribe_token_id,
          text_body: rendered.text,
        },
      });
      const deliveryId = await rpc("create_delivery_request", {
        p_intervention_id: interventionId,
        p_message_id: messageId,
        p_recipient_reference: context.recipient || context.message_recipient || context.recipient_reference,
        p_delivery_mode: context.delivery_mode,
        p_provider: "MAILERSEND",
        p_template_reference: context.template_reference || null,
        p_tracking_token: tracking.token,
        p_scheduled_at: new Date(now()).toISOString(),
        p_idempotency_key: "deliver:" + interventionId,
        p_correlation_id: context.correlation_id || job.correlation_id || null,
      });
      if (!isUuid(deliveryId)) throw new Error("delivery_request_creation_failed");

      const completed = await rpc("complete_job", { p_job_id: jobId, p_worker_id: id });
      if (completed !== true) throw new Error("job_completion_fence_lost");
      return json(200, { state: "DELIVERY_REQUEST_CREATED", delivery_request_id: deliveryId });
    } catch (error) {
      const reason = error instanceof Error ? error.message : "recovery_executor_failed";
      if (jobId) {
        try {
          if (claimed && interventionId) {
            await rpc("resolve_intervention_send_failure", {
              p_intervention_id: interventionId, p_final_status: "READY", p_reason: reason.slice(0, 300),
            });
          }
          await rpc("retry_job", {
            p_job_id: jobId, p_worker_id: id, p_error: reason.slice(0, 300), p_delay_seconds: 300,
          });
        } catch {
          // Lease/DB failures remain visible to the scheduler's stale-job repair.
        }
      }
      return json(503, { state: "RETRY_SCHEDULED", error: "recovery_execution_failed" });
    }
  };
}

export { STAGING_SUPABASE_URL, DEFAULT_MODEL, parseJsonContent };
