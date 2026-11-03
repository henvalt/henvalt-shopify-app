import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SHOPIFY_API_KEY = Deno.env.get("SHOPIFY_API_KEY") ?? "";
const SHOPIFY_API_SECRET = Deno.env.get("SHOPIFY_API_SECRET") ?? "";
const SHOPIFY_REDIRECT_URI = Deno.env.get("SHOPIFY_REDIRECT_URI") ?? "";
const SCOPES = [...new Set((Deno.env.get("SHOPIFY_SCOPES") ?? "read_orders").split(",").map((s) => s.trim()).filter(Boolean).concat("read_orders"))].join(",");
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
    authorize.searchParams.set("grant_options[]", "per-user");
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
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: SHOPIFY_API_KEY, client_secret: SHOPIFY_API_SECRET, code }),
    });
    if (!tokenRes.ok) {
      console.error("Shopify token exchange failed", tokenRes.status);
      return json(502, { error: "shopify_token_exchange_failed" });
    }
    const tokenData = await tokenRes.json();
    const accessToken = typeof tokenData.access_token === "string" ? tokenData.access_token : "";
    const scopes = typeof tokenData.scope === "string" ? tokenData.scope.split(",").map((s: string) => s.trim()).filter(Boolean) : [];
    if (!accessToken) return json(502, { error: "shopify_access_token_missing" });

    const shopRes = await fetch(`https://${shop}/admin/api/2026-10/shop.json`, { headers: { "x-shopify-access-token": accessToken, accept: "application/json" } });
    if (!shopRes.ok) {
      console.error("Shopify shop verification failed", shopRes.status);
      return json(502, { error: "shopify_shop_verification_failed" });
    }
    const shopData = await shopRes.json();
    const shopId = String(shopData?.shop?.id ?? "");
    if (!shopId) return json(502, { error: "shopify_shop_id_missing" });

    const finalized = await db("/rest/v1/rpc/control_plane_finalize_shopify_oauth_install_for_owner", {
      method: "POST",
      body: JSON.stringify({ p_state_hash: stateHash, p_shop_domain: shop, p_access_token: accessToken, p_shopify_shop_id: shopId, p_scopes: scopes, p_user_id: row.initiated_by_user_id }),
    });
    if (!finalized.ok) {
      console.error("OAuth finalization failed", finalized.status, (await finalized.text()).slice(0, 300));
      return json(503, { error: "oauth_install_persistence_failed" });
    }

    // Registration is intentionally explicit and checked; never silently mark it successful.
    const webhookUri = "https://henvalt-clean-ingress-v1.chmuhammadrehan18.workers.dev/shopify/webhooks";
    const specs = [{topic:"orders/create",gql:"ORDERS_CREATE"},{topic:"orders/paid",gql:"ORDERS_PAID"},{topic:"order_transactions/create",gql:"ORDER_TRANSACTIONS_CREATE"},{topic:"checkouts/create",gql:"CHECKOUTS_CREATE"},{topic:"checkouts/update",gql:"CHECKOUTS_UPDATE"},{topic:"carts/create",gql:"CARTS_CREATE"},{topic:"carts/update",gql:"CARTS_UPDATE"},{topic:"app/uninstalled",gql:"APP_UNINSTALLED"}];
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
    return json(200,{installed:true,shop,webhooksRegistered:allWebhooksRegistered,webhooks:results,message:allWebhooksRegistered?"HENVALT connected. Webhooks verified; you may close this page.":"Shop connected, but webhook registration needs attention."});
  }
  return json(404, { error: "not_found" });
});
