import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

type Rpc = (name: string, body: Record<string, unknown>) => Promise<any>;
type Dependencies = {
  supabaseUrl: string;
  serviceRoleKey: string;
  shopifyApiKey: string;
  shopifyApiSecret: string;
  rpc?: Rpc;
  fetchImpl?: typeof fetch;
};

function validShop(value: unknown): value is string {
  return typeof value === "string" &&
    /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(value.trim().toLowerCase());
}

function validLeaseId(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export function createTokenRefreshHandler(deps: Dependencies) {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const rpc: Rpc = deps.rpc ?? (async (name, body) => {
    const response = await fetchImpl(deps.supabaseUrl + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers: {
        apikey: deps.serviceRoleKey,
        authorization: "Bearer " + deps.serviceRoleKey,
        "content-type": "application/json",
        accept: "application/json",
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
  });

  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
    const auth = req.headers.get("authorization") ?? "";
    const bearer = auth.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    if (!deps.serviceRoleKey || !bearer || bearer !== deps.serviceRoleKey) {
      return json(401, { error: "service_role_required" });
    }
    if (!deps.supabaseUrl || !deps.shopifyApiKey || !deps.shopifyApiSecret) {
      return json(503, { error: "refresh_service_not_configured" });
    }

    let body: any;
    try { body = await req.json(); } catch { return json(400, { error: "invalid_json" }); }
    const shop = validShop(body?.shop_domain) ? body.shop_domain.trim().toLowerCase() : "";
    if (!shop) return json(400, { error: "valid_shop_domain_required" });
    const force = body?.force === true;

    let claim: any;
    try {
      claim = await rpc("claim_shopify_token_refresh", { p_shop_domain: shop, p_force: force });
    } catch {
      return json(503, { error: "refresh_claim_failed" });
    }
    if (!claim?.claimed) {
      const reason = typeof claim?.reason === "string" ? claim.reason : "NOT_CLAIMED";
      const status = reason === "REFRESH_ALREADY_IN_PROGRESS" || reason === "TOKEN_STILL_VALID" ||
          reason === "REAUTH_REQUIRED" ? 409 : reason === "CONNECTION_NOT_FOUND" ? 404 : 422;
      return json(status, { refreshed: false, reason, expires_at: claim?.expires_at ?? null });
    }

    const leaseId = validLeaseId(claim?.lease_id) ? claim.lease_id : "";
    if (!leaseId) {
      return json(503, { refreshed: false, error: "refresh_claim_contract_invalid", retryable: false });
    }
    if (typeof claim?.refresh_token !== "string" || claim.refresh_token.length < 20) {
      try {
        await rpc("fail_shopify_token_refresh", {
          p_shop_domain: shop, p_error_code: "refresh_claim_contract_invalid",
          p_reauth_required: false, p_lease_id: leaseId,
        });
      } catch {}
      return json(503, { refreshed: false, error: "refresh_claim_contract_invalid", retryable: false });
    }

    const form = new URLSearchParams({
      client_id: deps.shopifyApiKey,
      client_secret: deps.shopifyApiSecret,
      grant_type: "refresh_token",
      refresh_token: claim.refresh_token,
    });

    let tokenResponse: Response;
    try {
      tokenResponse = await fetchImpl("https://" + shop + "/admin/oauth/access_token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body: form,
        signal: AbortSignal.timeout(15000),
      });
    } catch {
      try {
        await rpc("fail_shopify_token_refresh", {
          p_shop_domain: shop, p_error_code: "shopify_network_error",
          p_reauth_required: false, p_lease_id: leaseId,
        });
      } catch {}
      return json(503, { refreshed: false, error: "shopify_network_error", retryable: true });
    }

    const tokenData: any = await tokenResponse.json().catch(() => ({}));
    if (!tokenResponse.ok) {
      const providerCode = typeof tokenData?.error === "string" ? tokenData.error : "shopify_refresh_rejected";
      const reauth = tokenResponse.status === 401 || providerCode === "invalid_request" ||
        providerCode === "invalid_grant";
      try {
        await rpc("fail_shopify_token_refresh", {
          p_shop_domain: shop, p_error_code: providerCode,
          p_reauth_required: reauth, p_lease_id: leaseId,
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
      try {
        await rpc("fail_shopify_token_refresh", {
          p_shop_domain: shop, p_error_code: "invalid_refresh_response",
          p_reauth_required: false, p_lease_id: leaseId,
        });
      } catch {}
      return json(502, { refreshed: false, error: "invalid_shopify_refresh_response", retryable: true });
    }

    try {
      const completed = await rpc("complete_shopify_token_refresh", {
        p_shop_domain: shop,
        p_access_token: accessToken,
        p_refresh_token: refreshToken,
        p_access_expires_in: accessExpiresIn,
        p_refresh_expires_in: refreshExpiresIn,
        p_lease_id: leaseId,
      });
      if (completed?.refreshed !== true) {
        const stale = completed?.reason === "STALE_REFRESH_LEASE";
        return json(stale ? 409 : 503, {
          refreshed: false,
          reason: stale ? "STALE_REFRESH_LEASE" : "TOKEN_PAIR_NOT_PERSISTED",
          retryable: !stale,
        });
      }
      return json(200, {
        refreshed: true,
        shop_domain: shop,
        access_expires_at: completed?.access_expires_at ?? null,
        refresh_expires_at: completed?.refresh_expires_at ?? null,
      });
    } catch {
      // If persistence failed before commit, Shopify permits retrying the same stored refresh token.
      // The lease ID ensures this cleanup cannot clear a newer worker's lease.
      try {
        await rpc("fail_shopify_token_refresh", {
          p_shop_domain: shop, p_error_code: "token_pair_persistence_failed",
          p_reauth_required: false, p_lease_id: leaseId,
        });
      } catch {}
      return json(503, { refreshed: false, error: "token_pair_persistence_failed", retryable: true });
    }
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";

if (import.meta.main) {
  Deno.serve(createTokenRefreshHandler({
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SERVICE_ROLE_KEY,
    shopifyApiKey: SHOPIFY_API_KEY,
    shopifyApiSecret: SHOPIFY_API_SECRET,
  }));
}
