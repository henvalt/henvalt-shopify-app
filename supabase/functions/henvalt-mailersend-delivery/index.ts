import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const json = (status: number, body: Record<string, unknown>, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extra,
    },
  });

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function validEmail(value: unknown): value is string {
  return typeof value === "string" &&
    value.length <= 254 &&
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

Deno.serve(async (req: Request) => {
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
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json(503, { error: "delivery_service_not_configured" });

  const authorization = req.headers.get("authorization") ?? "";
  const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
  if (!constantTimeEqual(bearer, SERVICE_ROLE_KEY)) {
    return json(401, { error: "service_role_required" });
  }

  let apiToken = "";
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

    if (!isUuid(tenantId) || !isUuid(deliveryRequestId)) {
      return json(400, { error: "invalid_delivery_identity" });
    }
    if (!validEmail(recipient) || !validEmail(sender) ||
        (replyTo != null && replyTo !== "" && !validEmail(replyTo))) {
      return json(400, { error: "invalid_email_address" });
    }
    if (typeof fromName !== "string" || fromName.trim().length < 1 || fromName.length > 120 ||
        typeof subject !== "string" || subject.trim().length < 1 || subject.length > 200) {
      return json(400, { error: "invalid_message_headers" });
    }
    if ((typeof html !== "string" || html.length < 1 || html.length > 100000) &&
        (typeof textBody !== "string" || textBody.length < 1 || textBody.length > 20000)) {
      return json(400, { error: "message_content_required" });
    }

    // Only a delivery request already claimed by authorize_delivery_request
    // (status UNKNOWN) can release its tenant-specific Vault credential.
    const tokenResponse = await fetch(
      SUPABASE_URL + "/rest/v1/rpc/get_mailersend_token_for_delivery",
      {
        method: "POST",
        headers: {
          apikey: SERVICE_ROLE_KEY,
          authorization: "Bearer " + SERVICE_ROLE_KEY,
          "content-type": "application/json",
          "accept-profile": "henvalt",
          "content-profile": "henvalt",
        },
        body: JSON.stringify({
          p_tenant_id: tenantId,
          p_delivery_request_id: deliveryRequestId,
        }),
      },
    );

    if (!tokenResponse.ok) return json(409, { error: "tenant_provider_credential_unavailable" });

    const tokenValue = await tokenResponse.json().catch(() => null);
    if (typeof tokenValue !== "string" || tokenValue.length < 20 || tokenValue.length > 512) {
      return json(409, { error: "tenant_provider_credential_unavailable" });
    }
    apiToken = tokenValue;

    const tags = ["tenant:" + tenantId, "delivery:" + deliveryRequestId];
    if (isUuid(body.intervention_id)) tags.push("intervention:" + body.intervention_id);
    if (isUuid(body.correlation_id)) tags.push("correlation:" + body.correlation_id);

    const message: Record<string, unknown> = {
      from: { email: sender, name: fromName },
      to: [{ email: recipient }],
      reply_to: { email: validEmail(replyTo) ? replyTo : sender },
      subject,
      tags,
    };
    if (typeof html === "string" && html.length > 0) message.html = html;
    if (typeof textBody === "string" && textBody.length > 0) message.text = textBody;

    let providerResponse: Response;
    try {
      providerResponse = await fetch("https://api.mailersend.com/v1/email", {
        method: "POST",
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
    let providerBody: unknown = {};
    if (raw) {
      try {
        providerBody = JSON.parse(raw);
      } catch {
        providerBody = { message: raw.slice(0, 1000) };
      }
    }

    const responseHeaders: Record<string, string> = {};
    const messageId = providerResponse.headers.get("x-message-id");
    if (messageId) responseHeaders["x-message-id"] = messageId;

    return json(
      providerResponse.status,
      providerBody && typeof providerBody === "object"
        ? providerBody as Record<string, unknown>
        : { result: providerBody },
      responseHeaders,
    );
  } catch {
    return json(500, { error: "delivery_provider_failed" });
  } finally {
    // The decrypted tenant credential is never returned or logged.
    apiToken = "";
  }
});
