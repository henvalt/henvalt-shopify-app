import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { isSingleActiveStoreScope } from "../_shared/dashboard-store-scope.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const APP_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";
const SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";
const headers = {
  "content-type": "application/json",
  "cache-control": "no-store",
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization,content-type",
  "access-control-allow-methods": "GET,OPTIONS",
};
const out = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers });

function decode(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(
    atob(normalized + "=".repeat((4 - normalized.length % 4) % 4)),
    (character) => character.charCodeAt(0),
  );
}

async function shopFromToken(token: string): Promise<string> {
  if (!APP_KEY || !SECRET) throw new Error("CONFIG_MISSING");
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("INVALID_TOKEN");
  const header = JSON.parse(new TextDecoder().decode(decode(parts[0])));
  const claims = JSON.parse(new TextDecoder().decode(decode(parts[1])));
  if (header.alg !== "HS256") throw new Error("INVALID_ALGORITHM");

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(parts[0] + "." + parts[1]),
  ));
  const supplied = decode(parts[2]);
  if (signature.length !== supplied.length ||
      signature.some((value, index) => value !== supplied[index])) {
    throw new Error("INVALID_SIGNATURE");
  }

  const shop = typeof claims.dest === "string"
    ? new URL(claims.dest).hostname.toLowerCase()
    : "";
  const now = Math.floor(Date.now() / 1000);
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ||
      claims.aud !== APP_KEY ||
      claims.iss !== "https://" + shop + "/admin" ||
      claims.dest !== "https://" + shop ||
      typeof claims.exp !== "number" ||
      claims.exp <= now ||
      (typeof claims.nbf === "number" && claims.nbf > now + 10)) {
    throw new Error("INVALID_SESSION");
  }
  return shop;
}

async function rpc(name: string, body: Record<string, unknown>): Promise<any> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: KEY,
      authorization: "Bearer " + KEY,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error("DATABASE_LOOKUP_FAILED");
  const payload = await response.json().catch(() => null);
  return Array.isArray(payload) ? payload[0] ?? null : payload;
}

async function rest(path: string): Promise<any> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/" + path, {
    headers: {
      apikey: KEY,
      authorization: "Bearer " + KEY,
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
    },
  });
  if (!response.ok) throw new Error("DATABASE_LOOKUP_FAILED");
  return await response.json();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "GET") return out(405, { error: "method_not_allowed" });

  try {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return out(401, { error: "shopify_session_required" });
    if (!SUPABASE_URL || !KEY) return out(503, { error: "dashboard_not_configured" });

    const shop = await shopFromToken(token);
    const connection = await rpc("control_plane_shop_connection", { p_shop_domain: shop });
    if (!connection ||
        typeof connection.connection_id !== "string" ||
        typeof connection.tenant_id !== "string" ||
        connection.active !== true ||
        connection.tenant_status !== "ACTIVE") {
      return out(409, { error: "shop_not_connected" });
    }

    // The current summary RPC aggregates legacy rows by tenant. Do not expose
    // those totals as shop-specific when any second connection exists, even
    // if that second connection is currently inactive.
    const tenantConnections = await rest(
      "shopify_connections?select=id,active&tenant_id=eq." +
      encodeURIComponent(connection.tenant_id) + "&limit=2",
    );
    if (!isSingleActiveStoreScope(tenantConnections, connection.connection_id)) {
      return out(409, { error: "store_specific_metrics_unavailable" });
    }

    const url = new URL(req.url);
    const valid = (value: string | null) =>
      value && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
    const today = new Date().toISOString().slice(0, 10);
    const from = valid(url.searchParams.get("from")) ||
      new Date(Date.now() - 29 * 86400000).toISOString().slice(0, 10);
    const to = valid(url.searchParams.get("to")) || today;
    if (to < from || Date.parse(to) - Date.parse(from) > 366 * 86400000) {
      return out(400, { error: "invalid_date_range" });
    }

    const summary = await rpc("control_plane_dashboard_summary", {
      p_shop_domain: shop,
      p_from: from + "T00:00:00.000Z",
      p_to: to + "T00:00:00.000Z",
    });
    if (!summary || summary.linked !== true) return out(409, { error: "shop_not_connected" });
    return out(200, {
      ...summary,
      shop,
      range: { from, to },
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "error";
    const status = message.includes("CONFIG_MISSING") ? 503 :
      message.startsWith("INVALID_") ? 401 : 500;
    return out(status, {
      error: status === 401 ? "invalid_shopify_session" :
        status === 503 ? "dashboard_auth_not_configured" : "dashboard_unavailable",
    });
  }
});
