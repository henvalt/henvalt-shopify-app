const MAX_BODY_BYTES = 12_000;
const ALLOWED_EVENTS = new Set([
  "page_viewed",
  "product_viewed",
  "product_added_to_cart",
  "checkout_started",
]);

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

async function sha256(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function validId(value, max) {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function safePageUrl(value) {
  if (typeof value !== "string" || value.length > 4096) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:") return null;
    // Never persist query strings or fragments; they can contain customer data.
    return url.origin + url.pathname.slice(0, 1000);
  } catch {
    return null;
  }
}

function safeOccurredAt(value) {
  if (typeof value === "string" && Number.isFinite(Date.parse(value))) {
    const parsed = new Date(value);
    const now = Date.now();
    if (parsed.getTime() <= now + 5 * 60_000 && parsed.getTime() >= now - 90 * 24 * 60 * 60_000) {
      return parsed.toISOString();
    }
  }
  return new Date().toISOString();
}

async function supabase(env, path, init = {}) {
  const response = await fetch(new URL(path, env.SUPABASE_URL), {
    ...init,
    headers: {
      apikey: env.SUPABASE_PUBLISHABLE_KEY,
      authorization: `Bearer ${env.SUPABASE_PUBLISHABLE_KEY}`,
      "content-type": "application/json",
      "accept-profile": "public",
      "content-profile": "public",
      ...(init.headers || {}),
    },
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) return { accepted: false, error: "collector_authentication_failed" };
    throw new Error(`Pixel ingest proxy failed: ${response.status}`);
  }
  return result;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "henvalt-pixel-collector", version: 1 });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/events") {
      return json({ error: "not_found" }, 404);
    }

    const origin = request.headers.get("origin") || "";
    const corsHeaders = {
      "access-control-allow-origin": origin,
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
      "access-control-max-age": "600",
      "vary": "Origin",
    };
    const corsJson = (body, status = 200) => new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...corsHeaders },
    });
    if (request.method === "OPTIONS") {
      if (url.pathname !== "/v1/events" || !origin.startsWith("https://")) return json({ error: "unauthorized" }, 403);
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    if (!origin || !origin.startsWith("https://")) {
      return corsJson({ error: "unauthorized" }, 401);
    }

    const contentLength = Number(request.headers.get("content-length") || "0");
    if (contentLength > MAX_BODY_BYTES) return corsJson({ error: "payload_too_large" }, 413);
    const raw = await request.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
      return json({ error: "payload_too_large" }, 413);
    }

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return corsJson({ error: "invalid_json" }, 400);
    }

    if (
      payload.schema_version !== 1 ||
      !validId(payload.event_id, 160) ||
      !ALLOWED_EVENTS.has(payload.event_type) ||
      !validId(payload.client_id, 160) ||
      !validId(payload.public_key, 300)
    ) {
      return corsJson({ error: "invalid_event" }, 400);
    }

    const digest = await sha256(payload.public_key);

    const rate = await env.RATE_LIMITER.limit({ key: `${digest}:${origin}` });
    if (!rate.success) return corsJson({ error: "rate_limited" }, 429);

    const checkoutReference = payload.event_type === "checkout_started" &&
      validId(payload.checkout_reference, 300)
      ? payload.checkout_reference
      : null;

    const canonicalPayload = {
      schema_version: 1,
      event_id: payload.event_id,
      event_type: payload.event_type,
      occurred_at: safeOccurredAt(payload.occurred_at),
      client_id: payload.client_id,
      page_url: safePageUrl(payload.page_url),
      product: payload.product ? {
        id: validId(payload.product.id, 200) ? payload.product.id : null,
        title: typeof payload.product.title === "string" ? payload.product.title.slice(0, 200) : null,
        variant_id: validId(payload.product.variant_id, 200) ? payload.product.variant_id : null,
      } : null,
      cart_line: payload.cart_line ? {
        quantity: Number.isInteger(payload.cart_line.quantity) && Number(payload.cart_line.quantity) >= 0
          ? Number(payload.cart_line.quantity)
          : null,
        merchandise_id: validId(payload.cart_line.merchandise_id, 200)
          ? payload.cart_line.merchandise_id
          : null,
      } : null,
      checkout_reference: checkoutReference,
    };

    const result = await supabase(
      env,
      "/functions/v1/henvalt-pixel-ingest-proxy",
      {
        method: "POST",
        body: JSON.stringify({
          p_key_digest: digest,
          p_origin: origin,
          p_collector_secret: env.COLLECTOR_SHARED_SECRET,
          p_payload: canonicalPayload,
        }),
      },
    );

    if (result.error === "rate_limited") return corsJson({ error: "rate_limited" }, 429);
    if (!result.accepted) return corsJson({ error: "event_rejected" }, 401);

    return corsJson({ accepted: true, duplicate: result.duplicate === true }, 202);
  },
};
