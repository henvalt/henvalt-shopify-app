import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SECRET_KEYS = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}"); }
  catch { return {}; }
})();
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  (typeof SECRET_KEYS.default === "string" ? SECRET_KEYS.default : "");

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error("Pixel ingest proxy service configuration missing");
    return json(503, { error: "collector_proxy_unavailable" });
  }

  let input: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (new TextEncoder().encode(raw).length > 12_288) return json(413, { error: "payload_too_large" });
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) return json(400, { error: "invalid_payload" });
    input = value as Record<string, unknown>;
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const keyDigest = typeof input.p_key_digest === "string" ? input.p_key_digest : "";
  const origin = typeof input.p_origin === "string" ? input.p_origin : "";
  const collectorSecret = typeof input.p_collector_secret === "string" ? input.p_collector_secret : "";
  const payload = input.p_payload;
  if (!/^[a-f0-9]{64}$/i.test(keyDigest) ||
      !/^https:\/\//i.test(origin) || origin.length > 512 ||
      collectorSecret.length < 32 || collectorSecret.length > 512 ||
      !payload || typeof payload !== "object" || Array.isArray(payload)) {
    return json(400, { error: "invalid_collector_request" });
  }

  try {
    const upstream = await fetch(SUPABASE_URL + "/rest/v1/rpc/henvalt_ingest_pixel_event", {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        authorization: "Bearer " + SERVICE_KEY,
        "content-type": "application/json",
        "accept-profile": "public",
        "content-profile": "public",
      },
      body: JSON.stringify({
        p_key_digest: keyDigest,
        p_origin: origin,
        p_collector_secret: collectorSecret,
        p_payload: payload,
      }),
      signal: AbortSignal.timeout(8000),
    });
    const text = await upstream.text();
    if (!upstream.ok) {
      console.error("Pixel ingest RPC rejected request", upstream.status);
      if ([400, 401, 403, 422].includes(upstream.status)) return json(401, { error: "pixel_event_rejected" });
      return json(503, { error: "collector_backend_unavailable" });
    }
    return new Response(text || "null", {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
  } catch (error) {
    console.error("Pixel ingest RPC unavailable", error instanceof Error ? error.message : "unknown_error");
    return json(503, { error: "collector_backend_unavailable" });
  }
});