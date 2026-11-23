import { assertEquals } from "jsr:@std/assert@1";
import { createTokenRefreshHandler } from "./index.ts";

const SHOP = "demo.myshopify.com";
const LEASE = "123e4567-e89b-42d3-a456-426614174000";
const ACCESS = "x".repeat(40);
const REFRESH = "r".repeat(40);
const depsBase = {
  supabaseUrl: "https://project.supabase.co",
  serviceRoleKey: "service-secret",
  shopifyApiKey: "shopify-key",
  shopifyApiSecret: "shopify-secret",
};

function request(body: unknown = { shop_domain: SHOP }) {
  return new Request("https://edge.example/refresh", {
    method: "POST",
    headers: { authorization: "Bearer service-secret", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
function tokenResponse(status = 200, payload: unknown = {
  access_token: ACCESS, refresh_token: REFRESH, expires_in: 3600, refresh_token_expires_in: 7776000,
}) {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}
function claim(leaseId: string | null = LEASE) {
  return { claimed: true, lease_id: leaseId, refresh_token: "stored-refresh-token-1234567890" };
}

Deno.test("requires service-role authentication and POST", async () => {
  const handler = createTokenRefreshHandler({ ...depsBase, rpc: async () => claim() });
  const get = await handler(new Request("https://edge.example/refresh"));
  const unauthorized = await handler(new Request("https://edge.example/refresh", { method: "POST" }));
  assertEquals(get.status, 405);
  assertEquals(unauthorized.status, 401);
});

Deno.test("rejects a claimed refresh without a valid lease ID before contacting Shopify", async () => {
  let shopifyCalls = 0;
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name) => name === "claim_shopify_token_refresh" ? claim("not-a-uuid") : {},
    fetchImpl: async () => { shopifyCalls++; return tokenResponse(); },
  });
  const response = await handler(request());
  assertEquals(response.status, 503);
  assertEquals((await response.json()).error, "refresh_claim_contract_invalid");
  assertEquals(shopifyCalls, 0);
});

Deno.test("persists the refreshed token pair with the exact claim lease ID", async () => {
  const rpcCalls: Array<{ name: string; body: Record<string, unknown> }> = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name, body) => {
      rpcCalls.push({ name, body });
      if (name === "claim_shopify_token_refresh") return claim();
      if (name === "complete_shopify_token_refresh") return {
        refreshed: true,
        access_expires_at: "2030-01-01T00:00:00Z",
        refresh_expires_at: "2030-03-01T00:00:00Z",
      };
      return { recorded: true };
    },
    fetchImpl: async (input) => {
      assertEquals(String(input), "https://" + SHOP + "/admin/oauth/access_token");
      return tokenResponse();
    },
  });
  const response = await handler(request());
  assertEquals(response.status, 200);
  const complete = rpcCalls.find((call) => call.name === "complete_shopify_token_refresh");
  assertEquals(complete?.body.p_lease_id, LEASE);
  assertEquals(complete?.body.p_access_token, ACCESS);
  assertEquals(complete?.body.p_refresh_token, REFRESH);
});

Deno.test("stale completion is rejected and never triggers stale failure cleanup", async () => {
  const rpcCalls: string[] = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name) => {
      rpcCalls.push(name);
      if (name === "claim_shopify_token_refresh") return claim();
      if (name === "complete_shopify_token_refresh") return {
        refreshed: false, reason: "STALE_REFRESH_LEASE",
      };
      return {};
    },
    fetchImpl: async () => tokenResponse(),
  });
  const response = await handler(request());
  assertEquals(response.status, 409);
  assertEquals((await response.json()).reason, "STALE_REFRESH_LEASE");
  assertEquals(rpcCalls.includes("fail_shopify_token_refresh"), false);
});

Deno.test("network failure passes lease ID to fenced failure RPC", async () => {
  const failBodies: Array<Record<string, unknown>> = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name, body) => {
      if (name === "fail_shopify_token_refresh") failBodies.push(body);
      if (name === "claim_shopify_token_refresh") return claim();
      return {};
    },
    fetchImpl: async () => { throw new Error("network down"); },
  });
  const response = await handler(request());
  assertEquals(response.status, 503);
  assertEquals(failBodies[0]?.p_lease_id, LEASE);
  assertEquals(failBodies[0]?.p_error_code, "shopify_network_error");
});

Deno.test("terminal Shopify refresh rejection passes lease ID and reauth flag", async () => {
  const failBodies: Array<Record<string, unknown>> = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name, body) => {
      if (name === "fail_shopify_token_refresh") failBodies.push(body);
      if (name === "claim_shopify_token_refresh") return claim();
      return {};
    },
    fetchImpl: async () => tokenResponse(401, { error: "invalid_request" }),
  });
  const response = await handler(request());
  assertEquals(response.status, 409);
  assertEquals(failBodies[0]?.p_lease_id, LEASE);
  assertEquals(failBodies[0]?.p_reauth_required, true);
});

Deno.test("invalid provider token pair is fenced when failure is recorded", async () => {
  const failBodies: Array<Record<string, unknown>> = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name, body) => {
      if (name === "fail_shopify_token_refresh") failBodies.push(body);
      if (name === "claim_shopify_token_refresh") return claim();
      return {};
    },
    fetchImpl: async () => tokenResponse(200, { access_token: ACCESS }),
  });
  const response = await handler(request());
  assertEquals(response.status, 502);
  assertEquals(failBodies[0]?.p_lease_id, LEASE);
  assertEquals(failBodies[0]?.p_error_code, "invalid_refresh_response");
});

Deno.test("persistence exception cleanup is fenced by the original lease ID", async () => {
  const failBodies: Array<Record<string, unknown>> = [];
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async (name, body) => {
      if (name === "claim_shopify_token_refresh") return claim();
      if (name === "complete_shopify_token_refresh") throw new Error("database unavailable");
      if (name === "fail_shopify_token_refresh") failBodies.push(body);
      return {};
    },
    fetchImpl: async () => tokenResponse(),
  });
  const response = await handler(request());
  assertEquals(response.status, 503);
  assertEquals(failBodies[0]?.p_lease_id, LEASE);
  assertEquals(failBodies[0]?.p_error_code, "token_pair_persistence_failed");
});

Deno.test("non-claimed refresh preserves existing conflict behavior", async () => {
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async () => ({ claimed: false, reason: "REFRESH_ALREADY_IN_PROGRESS" }),
  });
  const response = await handler(request());
  assertEquals(response.status, 409);
  assertEquals((await response.json()).reason, "REFRESH_ALREADY_IN_PROGRESS");
});

Deno.test("rejects invalid shop domains before claiming", async () => {
  let rpcCalls = 0;
  const handler = createTokenRefreshHandler({
    ...depsBase,
    rpc: async () => { rpcCalls++; return claim(); },
  });
  const response = await handler(request({ shop_domain: "https://demo.myshopify.com" }));
  assertEquals(response.status, 400);
  assertEquals(rpcCalls, 0);
});
