import { assertEquals, assert } from "jsr:@std/assert@1";

type Handler = (request: Request) => Response | Promise<Response>;

async function loadHandler(modulePath: string, tokenName: string): Promise<Handler> {
  Deno.env.set(tokenName, "runtime-lineage-test-secret");
  Deno.env.set("SUPABASE_URL", "https://supabase.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "runtime-lineage-test-service-key");
  // The handler must reach the database lineage resolver, but no provider send is permitted.
  Deno.env.set("HENVALT_V2_MAILERSEND_EVENTS_READY", "true");
  // Explicitly pass the independent send interlock to exercise deeper store-lineage rejection.
  Deno.env.set("HENVALT_V2_MAILERSEND_SEND_READY", "true");

  let captured: Handler | undefined;
  const originalServe = Deno.serve;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (handler: Handler) => { captured = handler; },
  });
  try {
    await import(modulePath);
  } finally {
    Object.defineProperty(Deno, "serve", { configurable: true, value: originalServe });
  }
  assert(captured, `Edge handler was not registered for ${modulePath}`);
  return captured;
}

const checkoutHandler = await loadHandler(
  "../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts",
  "HENVALT_DELIVERY_AUTH_TOKEN",
);
const pixelHandler = await loadHandler(
  "../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts",
  "HENVALT_PIXEL_DELIVERY_AUTH_TOKEN",
);

function rpcFixture(expectedContextRpc: string) {
  const calls: string[] = [];
  let nonRpcCalls = 0;
  const fetch = async (input: RequestInfo | URL): Promise<Response> => {
    const url = String(input);
    if (!url.includes("/rpc/")) {
      nonRpcCalls++;
      throw new Error("provider or Shopify network access is forbidden in lineage runtime test");
    }
    const name = url.split("/rpc/")[1]?.split(/[/?]/)[0] ?? "";
    calls.push(name);
    if (name === "resolve_shopify_recovery_message_context_v2") {
      return Response.json({ ready: true, shop_domain: "message-context.myshopify.com" });
    }
    if (name === expectedContextRpc) {
      // This is the fail-closed database resolver result for deliberately mismatched
      // tenant/store lineage. SQL integration tests separately exercise the real joins.
      return Response.json({ ready: false, code: "SHOPIFY_CONNECTION_MISMATCH" });
    }
    throw new Error(`Unexpected RPC in fail-closed lineage test: ${name}`);
  };
  return { fetch, calls, get nonRpcCalls() { return nonRpcCalls; } };
}

Deno.test("checkout delivery stops on exact-store context rejection before Shopify or MailerSend", async () => {
  const originalFetch = globalThis.fetch;
  const fixture = rpcFixture("resolve_shopify_delivery_context_v2");
  globalThis.fetch = fixture.fetch;
  try {
    const response = await checkoutHandler(new Request("https://edge.invalid", {
      method: "POST",
      headers: {
        authorization: "Bearer runtime-lineage-test-secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({ intervention_id: "00000000-0000-4000-8000-000000000001" }),
    }));
    assertEquals(response.status, 409);
    assertEquals(await response.json(), { error: "shopify_connection_mismatch" });
    assertEquals(fixture.calls, [
      "resolve_shopify_recovery_message_context_v2",
      "resolve_shopify_delivery_context_v2",
    ]);
    assertEquals(fixture.nonRpcCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("pixel delivery stops on exact-store context rejection before Shopify or MailerSend", async () => {
  const originalFetch = globalThis.fetch;
  const fixture = rpcFixture("resolve_shopify_pixel_delivery_context_v2");
  globalThis.fetch = fixture.fetch;
  try {
    const response = await pixelHandler(new Request("https://edge.invalid", {
      method: "POST",
      headers: {
        authorization: "Bearer runtime-lineage-test-secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({ opportunity_id: "00000000-0000-4000-8000-000000000002" }),
    }));
    assertEquals(response.status, 409);
    assertEquals(await response.json(), { error: "shopify_connection_mismatch" });
    assertEquals(fixture.calls, [
      "resolve_shopify_recovery_message_context_v2",
      "resolve_shopify_pixel_delivery_context_v2",
    ]);
    assertEquals(fixture.nonRpcCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
