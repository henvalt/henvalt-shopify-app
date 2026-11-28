const STAGING_SUPABASE_URL = "https://xidhtmrfvsgfmyltjuja.supabase.co";
const GROQ_CHAT_COMPLETIONS_URL = "https://api.groq.com/openai/v1/chat/completions";
const ALLOWED_MODELS = new Set(["openai/gpt-oss-120b"]);
const MAX_MESSAGE_CHARS = 16000;

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function constantTimeEqual(left, right) {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
  return mismatch === 0;
}

function validMessages(value) {
  if (!Array.isArray(value) || value.length !== 2) return false;
  if (value[0]?.role !== "system" || value[1]?.role !== "user") return false;
  return value.every((message) =>
    typeof message.content === "string" &&
    message.content.length > 0 &&
    message.content.length <= MAX_MESSAGE_CHARS
  );
}

export function createGroqGenerationHandler({
  supabaseUrl,
  serviceRoleKey,
  groqApiKey,
  fetchImpl = fetch,
}) {
  return async (request) => {
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
    if (supabaseUrl !== STAGING_SUPABASE_URL || !serviceRoleKey) {
      return json(503, { error: "staging_generation_service_not_configured" });
    }

    const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!constantTimeEqual(bearer, serviceRoleKey)) {
      return json(401, { error: "service_role_required" });
    }
    if (!groqApiKey || groqApiKey.length < 20) {
      return json(503, { error: "ai_provider_not_configured" });
    }

    let body;
    try {
      const raw = await request.text();
      if (raw.length > 40000) return json(413, { error: "request_too_large" });
      body = JSON.parse(raw);
    } catch {
      return json(400, { error: "invalid_json" });
    }

    const model = body?.model;
    const temperature = body?.temperature ?? 0.3;
    if (!ALLOWED_MODELS.has(model)) return json(400, { error: "model_not_allowed" });
    if (typeof temperature !== "number" || !Number.isFinite(temperature) || temperature < 0 || temperature > 0.5) {
      return json(400, { error: "temperature_out_of_range" });
    }
    if (body?.response_format?.type !== "json_object" || !validMessages(body?.messages)) {
      return json(400, { error: "invalid_generation_contract" });
    }
    if (body?.stream === true) return json(400, { error: "streaming_not_supported" });

    let upstream;
    try {
      upstream = await fetchImpl(GROQ_CHAT_COMPLETIONS_URL, {
        method: "POST",
        redirect: "error",
        headers: {
          authorization: "Bearer " + groqApiKey,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          model,
          temperature,
          response_format: { type: "json_object" },
          messages: body.messages,
          stream: false,
        }),
        signal: AbortSignal.timeout(25000),
      });
    } catch {
      return json(502, { error: "ai_provider_unavailable" });
    }

    if (!upstream.ok) {
      await upstream.arrayBuffer().catch(() => new ArrayBuffer(0));
      return json(502, { error: "ai_provider_request_failed" });
    }

    let result;
    try {
      result = await upstream.json();
    } catch {
      return json(502, { error: "ai_provider_invalid_response" });
    }

    const content = result?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.length === 0 || content.length > 12000) {
      return json(502, { error: "ai_provider_invalid_response" });
    }

    return json(200, {
      choices: [{ message: { role: "assistant", content } }],
      model,
    });
  };
}

export { ALLOWED_MODELS, GROQ_CHAT_COMPLETIONS_URL, STAGING_SUPABASE_URL };
