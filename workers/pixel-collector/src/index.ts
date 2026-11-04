export interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  RATE_LIMITER: { limit(input: { key: string }): Promise<{ success: boolean }> };
}

const MAX_BODY_BYTES = 12_000;
const ALLOWED_EVENTS = new Set([
  "page_viewed",
  "product_viewed",
  "product_added_to_cart",
  "checkout_started",
]);

type PixelPayload = {
  schema_version: number;
  event_id: string;
  event_type: string;
  occurred_at?: string | null;
  client_id: string;
  page_url?: string | null;
  product?: { id?: string | null; title?: string | null; variant_id?: string | null } | null;
  cart_line?: { quantity?: number | null; merchandise_id?: string | null } | null;
  checkout_reference?: string | null;
  public_key: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function validId(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function safeOccurredAt(value: unknown): string {
  if (typeof value === "string" && Number.isFinite(Date.parse(value))) {
    const parsed = new Date(value);
    const now = Date.now();
    if (parsed.getTime() <= now + 5 * 60_000 && parsed.getTime() >= now - 90 * 24 * 60 * 60_000) {
      return parsed.toISOString();
    }
  }
  return new Date().toISOString();
}

async function supabase<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(new URL(path, env.SUPABASE_URL), {
    ...init,
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
      ...(init.headers || {}),
    },
  });
  if (!response.ok) throw new Error(`Supabase request failed: ${response.status}`);
  return await response.json() as T;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "henvalt-pixel-collector", version: 1 });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/events") {
      return json({ error: "not_found" }, 404);
    }

    const origin = request.headers.get("origin") || "";
    if (!origin || !origin.startsWith("https://")) {
      return json({ error: "unauthorized" }, 401);
    }

    const contentLength = Number(request.headers.get("content-length") || "0");
    if (contentLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
    const raw = await request.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
      return json({ error: "payload_too_large" }, 413);
    }

    let payload: PixelPayload;
    try {
      payload = JSON.parse(raw) as PixelPayload;
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    if (
      payload.schema_version !== 1 ||
      !validId(payload.event_id, 160) ||
      !ALLOWED_EVENTS.has(payload.event_type) ||
      !validId(payload.client_id, 160) ||
      !validId(payload.public_key, 300)
    ) {
      return json({ error: "invalid_event" }, 400);
    }

    const digest = await sha256(payload.public_key);
    const keyRows = await supabase<Array<{
      tenant_id: string;
      allowed_origins: string[];
      active: boolean;
    }>>(env, `/rest/v1/pixel_keys?key_digest=eq.${digest}&active=eq.true&select=tenant_id,allowed_origins,active`);

    const key = keyRows[0];
    if (!key || !key.active || !key.allowed_origins.includes(origin)) {
      return json({ error: "unauthorized" }, 401);
    }
    const corsHeaders = {
      "access-control-allow-origin": origin,
      "access-control-allow-methods": "POST",
      "access-control-allow-headers": "content-type",
      "vary": "Origin",
    };
    const corsJson = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...corsHeaders },
    });

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
      page_url: typeof payload.page_url === "string" ? payload.page_url.slice(0, 1200) : null,
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

    const eventType = payload.event_type.toUpperCase();
    const idempotencyKey = `shopify-pixel:${payload.event_id}`;
    const inserted = await supabase<Array<{ event_id: string; is_duplicate: boolean }>>(
      env,
      "/rest/v1/rpc/upsert_canonical_event",
      {
        method: "POST",
        body: JSON.stringify({
          p_tenant_id: key.tenant_id,
          p_webhook_event_id: null,
          p_event_type: eventType,
          p_event_class: "OTHER",
          p_source: "SHOPIFY_WEB_PIXEL",
          p_source_event_id: payload.event_id,
          p_customer_reference: null,
          p_email: null,
          p_anonymous_reference: payload.client_id,
          p_session_reference: payload.client_id,
          p_occurred_at: safeOccurredAt(payload.occurred_at),
          p_value_at_risk: null,
          p_currency: null,
          p_payload: canonicalPayload,
          p_metadata: { collector_version: 1, consent_context: "shopify_pixel_customer_privacy" },
          p_idempotency_key: idempotencyKey,
          p_correlation_id: null,
        }),
      },
    );

    const eventId = inserted[0]?.event_id;
    if (!eventId) throw new Error("Canonical event insert returned no event ID");

    await supabase(env, "/rest/v1/rpc/resolve_identity", {
      method: "POST",
      body: JSON.stringify({ p_event_id: eventId }),
    });

    if (checkoutReference) {
      await supabase(env, "/rest/v1/rpc/bind_session_alias", {
        method: "POST",
        body: JSON.stringify({
          p_tenant_id: key.tenant_id,
          p_alias_reference: checkoutReference,
          p_session_reference: payload.client_id,
        }),
      });
    }

    return corsJson({ accepted: true, duplicate: inserted[0].is_duplicate === true }, 202);
  },
};
