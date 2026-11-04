import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

async function rpc(name: string, body: Record<string, unknown>): Promise<any> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
      "accept-profile": "henvalt",
      "content-profile": "henvalt",
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    console.error("Shopify token refresh database operation failed", name, response.status);
    throw new Error("TOKEN_STORAGE_OPERATION_FAILED");
  }
  return payload;
}

function validShop(value: unknown): value is string {
  return typeof value === "string" &&
    /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(value.trim().toLowerCase());
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const auth = req.headers.get("authorization") ?? "";
  const bearer = auth.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
  if (!SERVICE_ROLE_KEY || !bearer || bearer !== SERVICE_ROLE_KEY) {
    return json(401, { error: "service_role_required" });
  }
  if (!SUPABASE_URL || !SHOPIFY_API_KEY || !SHOPIFY_API_SECRET) {
    return json(503, { error: "refresh_service_not_configured" });
  }

  let body: any;
  try { body = await req.json(); } catch { return json(400, { error: "invalid_json" }); }
  const shop = validShop(body?.shop_domain) ? body.shop_domain.trim().toLowerCase() : "";
  if (!shop) return json(400, { error: "valid_shop_domain_required" });
  const force = body?.force === true;

  let claim: any;
  try {
    claim = await rpc("claim_shopify_token_refresh", {
      p_shop_domain: shop,
      p_force: force,
    });
  } catch {
    return json(503, { error: "refresh_claim_failed" });
  }
  if (!claim?.claimed) {
    const reason = typeof claim?.reason === "string" ? claim.reason : "NOT_CLAIMED";
    const status = reason === "REFRESH_ALREADY_IN_PROGRESS" || reason === "TOKEN_STILL_VALID" ? 409 :
      reason === "REAUTH_REQUIRED" ? 409 : reason === "CONNECTION_NOT_FOUND" ? 404 : 422;
    return json(status, { refreshed: false, reason, expires_at: claim?.expires_at ?? null });
  }

  const form = new URLSearchParams({
    client_id: SHOPIFY_API_KEY,
    client_secret: SHOPIFY_API_SECRET,
    grant_type: "refresh_token",
    refresh_token: claim.refresh_token,
  });

  let tokenResponse: Response;
  try {
    tokenResponse = await fetch(`https://${shop}/admin/oauth/access_token`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
      },
      body: form,
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    try { await rpc("fail_shopify_token_refresh", { p_shop_domain: shop, p_error_code: "shopify_network_error", p_reauth_required: false }); } catch {}
    return json(503, { refreshed: false, error: "shopify_network_error", retryable: true });
  }

  const tokenData: any = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok) {
    const providerCode = typeof tokenData?.error === "string" ? tokenData.error : "shopify_refresh_rejected";
    const reauth = tokenResponse.status === 401 || providerCode === "invalid_request" ||
      providerCode === "invalid_grant";
    try {
      await rpc("fail_shopify_token_refresh", {
        p_shop_domain: shop,
        p_error_code: providerCode,
        p_reauth_required: reauth,
      });
    } catch {}
    const status = tokenResponse.status >= 500 || tokenResponse.status === 429 ? 503 : 409;
    return json(status, {
      refreshed: false,
      error: reauth ? "reauthorization_required" : "shopify_refresh_failed",
      retryable: !reauth && (tokenResponse.status >= 500 || tokenResponse.status === 429),
    });
  }

  const accessToken = typeof tokenData.access_token === "string" ? tokenData.access_token : "";
  const refreshToken = typeof tokenData.refresh_token === "string" ? tokenData.refresh_token : "";
  const accessExpiresIn = Number(tokenData.expires_in);
  const refreshExpiresIn = Number(tokenData.refresh_token_expires_in);
  if (!accessToken || !refreshToken || !Number.isFinite(accessExpiresIn) || accessExpiresIn < 60 ||
      !Number.isFinite(refreshExpiresIn) || refreshExpiresIn < 60) {
    try { await rpc("fail_shopify_token_refresh", { p_shop_domain: shop, p_error_code: "invalid_refresh_response", p_reauth_required: false }); } catch {}
    return json(502, { refreshed: false, error: "invalid_shopify_refresh_response", retryable: true });
  }

  try {
    const completed = await rpc("complete_shopify_token_refresh", {
      p_shop_domain: shop,
      p_access_token: accessToken,
      p_refresh_token: refreshToken,
      p_access_expires_in: accessExpiresIn,
      p_refresh_expires_in: refreshExpiresIn,
    });
    return json(200, {
      refreshed: completed?.refreshed === true,
      shop_domain: shop,
      access_expires_at: completed?.access_expires_at ?? null,
      refresh_expires_at: completed?.refresh_expires_at ?? null,
    });
  } catch {
    // Shopify keeps the presented refresh token retryable until the replacement is used.
    // Do not mark reauthorization required; a retry with the stored token can recover the pair.
    try { await rpc("fail_shopify_token_refresh", { p_shop_domain: shop, p_error_code: "token_pair_persistence_failed", p_reauth_required: false }); } catch {}
    return json(503, { refreshed: false, error: "token_pair_persistence_failed", retryable: true });
  }
});
