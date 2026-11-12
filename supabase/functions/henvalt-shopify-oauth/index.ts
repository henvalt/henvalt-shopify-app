import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";
const SHOPIFY_REDIRECT_URI = Deno.env.get("SHOPIFY_REDIRECT_URI") ?? "";
const SCOPES = [...new Set((Deno.env.get("SHOPIFY_SCOPES") ?? "read_orders,read_customers,write_pixels,read_customer_events").split(",").map((s) => s.trim()).filter(Boolean).concat(["read_orders", "read_customers", "write_pixels", "read_customer_events"]))].join(",");
const STATE_TTL_SECONDS = 600;

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type", "access-control-allow-methods": "GET, POST, OPTIONS" } });
const redirect = (url: string) => new Response(null, { status: 302, headers: { location: url, "cache-control": "no-store" } });

function validShop(value: string | null): string | null {
  if (!value) return null;
  const shop = value.trim().toLowerCase();
  return /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(shop) ? shop : null;
}
function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let d = 0; for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}
async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return [...sig].map(v => v.toString(16).padStart(2, "0")).join("");
}
async function sha256(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...bytes].map(v => v.toString(16).padStart(2, "0")).join("");
}
async function db(path: string, init: RequestInit = {}, schema = "henvalt"): Promise<Response> {
  return fetch(SUPABASE_URL + path, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      "content-type": "application/json",
      "accept-profile": schema,
      "content-profile": schema,
      ...(init.headers ?? {}),
    },
  });
}
function configOk(): boolean {
  return Boolean(SUPABASE_URL && SERVICE_ROLE_KEY && SHOPIFY_API_KEY && SHOPIFY_API_SECRET && SHOPIFY_REDIRECT_URI);
}
async function verifyCallbackHmac(params: URLSearchParams): Promise<boolean> {
  const supplied = params.get("hmac");
  if (!supplied) return false;
  const entries = [...params.entries()].filter(([k]) => k !== "hmac" && k !== "signature").sort(([a], [b]) => a.localeCompare(b));
  const message = entries.map(([k, v]) => `${k}=${v}`).join("&");
  return constantTimeEqual(await hmacHex(SHOPIFY_API_SECRET, message), supplied.toLowerCase());
}

async function activateShopifyPixel(shop: string, accessToken: string, tenantId: string, connectionId: string): Promise<Record<string, unknown>> {
  const graphUrl = `https://${shop}/admin/api/2026-10/graphql.json`;
  const graph = async (query: string, variables: Record<string, unknown> = {}) => {
    const response = await fetch(graphUrl, {
      method: "POST",
      headers: { "x-shopify-access-token": accessToken, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.timeout(15000),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.errors?.length) throw new Error("SHOPIFY_GRAPHQL_REQUEST_FAILED");
    return payload?.data ?? {};
  };

  const shopData = await graph("query { shop { primaryDomain { url } } }");
  let primaryOrigin = `https://${shop}`;
  try {
    const primaryUrl = new URL(String(shopData?.shop?.primaryDomain?.url ?? ""));
    if (primaryUrl.protocol === "https:") primaryOrigin = primaryUrl.origin;
  } catch {
    // Keep the canonical myshopify.com origin if the primary domain is unavailable.
  }
  const allowedOrigins = [...new Set([primaryOrigin, `https://${shop}`])];

  // Reuse the existing Shopify Web Pixel on reauthorization instead of creating duplicates.
  const existingResponse = await db(
    `/rest/v1/pixel_keys?select=id,shopify_web_pixel_id&shopify_connection_id=eq.${encodeURIComponent(connectionId)}&active=eq.true&order=created_at.desc&limit=1`,
  );
  if (!existingResponse.ok) return { activated: false, error: "EXISTING_PIXEL_LOOKUP_FAILED" };
  const existingRows = await existingResponse.json().catch(() => []);
  const existing = Array.isArray(existingRows) ? existingRows[0] : null;
  if (existing && !existing.shopify_web_pixel_id) {
    // Do not create a second pixel when an earlier activation lacks its persisted Shopify ID.
    return { activated: false, error: "EXISTING_PIXEL_ID_NOT_PERSISTED" };
  }

  const keyBytes = crypto.getRandomValues(new Uint8Array(32));
  const publicKey = [...keyBytes].map((value) => value.toString(16).padStart(2, "0")).join("");
  const keyDigest = await sha256(publicKey);
  const inserted = await db("/rest/v1/pixel_keys?select=id", {
    method: "POST",
    headers: { prefer: "return=representation" },
    body: JSON.stringify({
      tenant_id: tenantId,
      shopify_connection_id: connectionId,
      key_digest: keyDigest,
      allowed_origins: allowedOrigins,
      active: true,
    }),
  });
  if (!inserted.ok) {
    console.error("Pixel key provisioning failed", inserted.status);
    return { activated: false, error: "PIXEL_KEY_PROVISIONING_FAILED" };
  }
  const insertedRows = await inserted.json().catch(() => []);
  const keyId = Array.isArray(insertedRows) && typeof insertedRows[0]?.id === "string"
    ? insertedRows[0].id
    : "";
  if (!keyId) return { activated: false, error: "PIXEL_KEY_ID_MISSING" };

  const settings = {
    collectorUrl: "https://henvalt-pixel-collector.chmuhammadrehan18.workers.dev/v1/events",
    publicKey,
  };
  const isUpdate = typeof existing?.shopify_web_pixel_id === "string";
  const mutation = isUpdate
    ? `mutation UpdateHenvaltPixel($id: ID!, $webPixel: WebPixelInput!) {
        webPixelUpdate(id: $id, webPixel: $webPixel) {
          userErrors { field message code }
          webPixel { id settings }
        }
      }`
    : `mutation CreateHenvaltPixel($webPixel: WebPixelInput!) {
        webPixelCreate(webPixel: $webPixel) {
          userErrors { field message code }
          webPixel { id settings }
        }
      }`;
  let pixelPayload: any;
  try {
    pixelPayload = await graph(mutation, isUpdate
      ? { id: existing.shopify_web_pixel_id, webPixel: { settings } }
      : { webPixel: { settings } });
  } catch {
    await db(`/rest/v1/pixel_keys?id=eq.${encodeURIComponent(keyId)}`, {
      method: "PATCH",
      headers: { prefer: "return=minimal" },
      body: JSON.stringify({ active: false, revoked_at: new Date().toISOString() }),
    });
    return { activated: false, error: "SHOPIFY_PIXEL_MUTATION_FAILED" };
  }

  const result = isUpdate ? pixelPayload?.webPixelUpdate : pixelPayload?.webPixelCreate;
  const pixel = result?.webPixel;
  const userErrors = result?.userErrors ?? [];
  if (userErrors.length || !pixel?.id) {
    await db(`/rest/v1/pixel_keys?id=eq.${encodeURIComponent(keyId)}`, {
      method: "PATCH",
      headers: { prefer: "return=minimal" },
      body: JSON.stringify({ active: false, revoked_at: new Date().toISOString() }),
    });
    console.error("Shopify Web Pixel mutation rejected", userErrors.map((item: any) => item.code ?? "USER_ERROR").join(","));
    return { activated: false, error: "SHOPIFY_PIXEL_MUTATION_REJECTED" };
  }

  const persisted = await db(`/rest/v1/pixel_keys?id=eq.${encodeURIComponent(keyId)}`, {
    method: "PATCH",
    headers: { prefer: "return=minimal" },
    body: JSON.stringify({ shopify_web_pixel_id: pixel.id }),
  });
  if (!persisted.ok) {
    // Keep the new key active so the successfully updated pixel can still ingest events.
    console.error("Shopify Web Pixel ID persistence failed", persisted.status);
    return { activated: true, pixelId: pixel.id, pixelIdPersisted: false, previousKeysRevoked: false };
  }

  const revoked = await db(
    `/rest/v1/pixel_keys?shopify_connection_id=eq.${encodeURIComponent(connectionId)}&active=eq.true&id=neq.${encodeURIComponent(keyId)}`,
    {
      method: "PATCH",
      headers: { prefer: "return=minimal" },
      body: JSON.stringify({ active: false, revoked_at: new Date().toISOString() }),
    },
  );
  if (!revoked.ok) console.error("Pixel key rotation warning: previous active keys could not be revoked", revoked.status);

  return {
    activated: true,
    pixelId: pixel.id,
    pixelUpdated: isUpdate,
    pixelIdPersisted: true,
    allowedOriginCount: allowedOrigins.length,
    previousKeysRevoked: revoked.ok,
  };
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization, apikey, content-type",
      "access-control-allow-methods": "GET, POST, OPTIONS",
      "cache-control": "no-store",
    } });
  }
  if (req.method !== "GET" && req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  if (route === "health" && req.method === "GET") return json(200, { service: "henvalt-shopify-oauth", configured: configOk() });
  if (!configOk()) return json(503, { error: "oauth_configuration_missing" });

  if (route === "auth" || route === "install") {
    const authorization = req.headers.get("authorization") ?? "";
    const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
    if (!bearer) return json(401, { error: "authenticated_merchant_required" });
    const userResponse = await fetch(SUPABASE_URL + "/auth/v1/user", { headers: { apikey: SERVICE_ROLE_KEY, authorization: "Bearer " + bearer } });
    if (!userResponse.ok) return json(401, { error: "invalid_merchant_session" });
    const userData = await userResponse.json();
    const userId = typeof userData?.id === "string" ? userData.id : "";
    if (!userId) return json(401, { error: "invalid_merchant_session" });
    const requestBody = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const shop = validShop(req.method === "POST" ? requestBody.shop : url.searchParams.get("shop"));
    if (!shop) return json(400, { error: "valid_shop_required" });
    const stateBytes = crypto.getRandomValues(new Uint8Array(32));
    const state = [...stateBytes].map(v => v.toString(16).padStart(2, "0")).join("");
    const stateHash = await sha256(state);
    const expiresAt = new Date(Date.now() + STATE_TTL_SECONDS * 1000).toISOString();
    const stored = await db("/rest/v1/shopify_oauth_states", {
      method: "POST",
      headers: { prefer: "return=minimal" },
      body: JSON.stringify({ state_hash: stateHash, shop_domain: shop, expires_at: expiresAt, initiated_by_user_id: userId }),
    });
    if (!stored.ok) {
      console.error("OAuth state insert failed", stored.status, (await stored.text()).slice(0, 250));
      return json(503, { error: "oauth_state_storage_failed" });
    }
    const authorize = new URL(`https://${shop}/admin/oauth/authorize`);
    authorize.searchParams.set("client_id", SHOPIFY_API_KEY);
    authorize.searchParams.set("scope", SCOPES);
    authorize.searchParams.set("redirect_uri", SHOPIFY_REDIRECT_URI);
    authorize.searchParams.set("state", state);
    return req.method === "POST" ? json(200, { authorize_url: authorize.toString() }) : redirect(authorize.toString());
  }

  if (route === "callback") {
    if (req.method !== "GET") return json(405, { error: "method_not_allowed" });
    const shop = validShop(url.searchParams.get("shop"));
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!shop || !code || !state || !(await verifyCallbackHmac(url.searchParams))) return json(400, { error: "invalid_oauth_callback" });

    const stateHash = await sha256(state);
    const stateRes = await db("/rest/v1/shopify_oauth_states?select=shop_domain,expires_at,consumed_at,initiated_by_user_id&state_hash=eq." + stateHash);
    if (!stateRes.ok) return json(503, { error: "oauth_state_lookup_failed" });
    const stateRows = await stateRes.json();
    const row = Array.isArray(stateRows) ? stateRows[0] : null;
    if (!row || row.shop_domain !== shop || !row.initiated_by_user_id || row.consumed_at || Date.parse(row.expires_at) <= Date.now()) return json(400, { error: "invalid_or_expired_oauth_state" });

    const tokenRes = await fetch(`https://${shop}/admin/oauth/access_token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: SHOPIFY_API_KEY, client_secret: SHOPIFY_API_SECRET, code, expiring: "1" }),
    });
    if (!tokenRes.ok) {
      console.error("Shopify token exchange failed", tokenRes.status);
      return json(502, { error: "shopify_token_exchange_failed" });
    }
    const tokenData = await tokenRes.json();
    const accessToken = typeof tokenData.access_token === "string" ? tokenData.access_token : "";
    const refreshToken = typeof tokenData.refresh_token === "string" ? tokenData.refresh_token : "";
    const accessExpiresIn = Number(tokenData.expires_in);
    const refreshExpiresIn = Number(tokenData.refresh_token_expires_in);
    const scopes = typeof tokenData.scope === "string" ? tokenData.scope.split(",").map((s: string) => s.trim()).filter(Boolean) : [];
    if (!accessToken || !refreshToken || !Number.isFinite(accessExpiresIn) || accessExpiresIn < 60 ||
        !Number.isFinite(refreshExpiresIn) || refreshExpiresIn < accessExpiresIn) {
      console.error("Shopify expiring offline token response incomplete");
      return json(502, { error: "shopify_expiring_offline_token_response_invalid" });
    }

    const shopRes = await fetch(`https://${shop}/admin/api/2026-10/shop.json`, { headers: { "x-shopify-access-token": accessToken, accept: "application/json" } });
    if (!shopRes.ok) {
      console.error("Shopify shop verification failed", shopRes.status);
      return json(502, { error: "shopify_shop_verification_failed" });
    }
    const shopData = await shopRes.json();
    const shopId = String(shopData?.shop?.id ?? "");
    if (!shopId) return json(502, { error: "shopify_shop_id_missing" });

    const finalized = await db("/rest/v1/rpc/control_plane_finalize_shopify_oauth_install_expiring_for_owner", {
      method: "POST",
      body: JSON.stringify({
        p_state_hash: stateHash,
        p_shop_domain: shop,
        p_access_token: accessToken,
        p_refresh_token: refreshToken,
        p_access_expires_in: accessExpiresIn,
        p_refresh_expires_in: refreshExpiresIn,
        p_shopify_shop_id: shopId,
        p_scopes: scopes,
        p_user_id: row.initiated_by_user_id,
      }),
    });
    if (!finalized.ok) {
      console.error("OAuth finalization failed", finalized.status, (await finalized.text()).slice(0, 300));
      return json(503, { error: "oauth_install_persistence_failed" });
    }
    const finalizedData = await finalized.json().catch(() => ({}));
    const tenantId = typeof finalizedData?.tenant_id === "string" ? finalizedData.tenant_id : "";
    const connectionId = typeof finalizedData?.connection_id === "string" ? finalizedData.connection_id : "";
    let pixelActivation: Record<string, unknown> = { activated: false, error: "TENANT_OR_CONNECTION_ID_MISSING" };
    if (tenantId && connectionId && scopes.includes("write_pixels") && scopes.includes("read_customer_events")) {
      try {
        pixelActivation = await activateShopifyPixel(shop, accessToken, tenantId, connectionId);
      } catch (error) {
        console.error("Shopify pixel activation failed unexpectedly", error instanceof Error ? error.message : "unknown_error");
        pixelActivation = { activated: false, error: "PIXEL_ACTIVATION_UNAVAILABLE" };
      }
    } else {
      pixelActivation = { activated: false, error: "REQUIRED_PIXEL_SCOPES_MISSING" };
    }

    // Registration is intentionally explicit and checked; never silently mark it successful.
    const webhookUri = "https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks";
    const specs = [{topic:"orders/create",gql:"ORDERS_CREATE"},{topic:"orders/paid",gql:"ORDERS_PAID"},{topic:"orders/cancelled",gql:"ORDERS_CANCELLED"},{topic:"refunds/create",gql:"REFUNDS_CREATE"},{topic:"order_transactions/create",gql:"ORDER_TRANSACTIONS_CREATE"},{topic:"checkouts/create",gql:"CHECKOUTS_CREATE"},{topic:"checkouts/update",gql:"CHECKOUTS_UPDATE"},{topic:"carts/create",gql:"CARTS_CREATE"},{topic:"carts/update",gql:"CARTS_UPDATE"},{topic:"customers_email_marketing_consent/update",gql:"CUSTOMERS_EMAIL_MARKETING_CONSENT_UPDATE"},{topic:"app/uninstalled",gql:"APP_UNINSTALLED"}];
    const results: Array<Record<string, unknown>> = [];
    async function gql(query:string,variables:Record<string,unknown>={}) {
      const res=await fetch(`https://${shop}/admin/api/2026-10/graphql.json`,{method:"POST",headers:{"x-shopify-access-token":accessToken,"content-type":"application/json",accept:"application/json"},body:JSON.stringify({query,variables})});
      const d=await res.json().catch(()=>({}));
      if(!res.ok||d.errors?.length) throw new Error("graphql_failed");
      return d.data;
    }
    for(const spec of specs) {
      try {
        let nodes=(await gql("query { webhookSubscriptions(first:100) { nodes { id topic uri } } }")).webhookSubscriptions?.nodes??[];
        let found=nodes.find((x:any)=>x.topic===spec.gql&&x.uri===webhookUri);
        if(!found) {
          const d=await gql("mutation CreateWebhook($topic: WebhookSubscriptionTopic!, $input: WebhookSubscriptionInput!) { webhookSubscriptionCreate(topic:$topic,webhookSubscription:$input) { userErrors { message } webhookSubscription { id topic uri } } }",{topic:spec.gql,input:{uri:webhookUri,format:"JSON"}});
          const p=d.webhookSubscriptionCreate;
          if(p?.userErrors?.length||!p?.webhookSubscription?.id){results.push({topic:spec.topic,ok:false,error:(p?.userErrors??[]).map((e:any)=>e.message).join("; ")||"not_created"});continue;}
        }
        results.push({topic:spec.topic,ok:true});
      } catch { results.push({topic:spec.topic,ok:false,error:"registration_failed"}); }
    }
    let finalNodes:any[]=[];
    try{finalNodes=(await gql("query { webhookSubscriptions(first:100) { nodes { id topic uri } } }")).webhookSubscriptions?.nodes??[];}catch{}
    for(const r of results){const s=specs.find(x=>x.topic===r.topic);const f=s&&finalNodes.find((x:any)=>x.topic===s.gql&&x.uri===webhookUri);r.verified=!!f;r.ok=r.ok===true&&!!f;if(f)r.id=f.id;}
    const allWebhooksRegistered=results.length===specs.length&&results.every(x=>x.ok===true&&x.verified===true);
    const pixelActivated = pixelActivation.activated === true;
    const completionUrl = new URL("https://henvalt-dashboard.lovable.app/settings");
    completionUrl.searchParams.set("shopify_status", "connected");
    completionUrl.searchParams.set("shop", shop);
    completionUrl.searchParams.set("pixel_status", pixelActivated ? "active" : "attention");
    completionUrl.searchParams.set("webhooks_status", allWebhooksRegistered ? "verified" : "attention");
    if (!pixelActivated && typeof pixelActivation.error === "string") {
      completionUrl.searchParams.set("pixel_issue", pixelActivation.error);
    }
    return redirect(completionUrl.toString());
  }
  return json(404, { error: "not_found" });
});
