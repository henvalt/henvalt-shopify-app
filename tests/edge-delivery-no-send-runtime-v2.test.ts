import { assertEquals, assert } from "jsr:@std/assert@1";

type Handler = (request: Request) => Response | Promise<Response>;

async function loadHandler(modulePath: string, prefix: "checkout" | "pixel"): Promise<Handler> {
  const names = prefix === "checkout"
    ? ["HENVALT_DELIVERY_AUTH_TOKEN"]
    : ["HENVALT_PIXEL_DELIVERY_AUTH_TOKEN"];
  for (const name of names) Deno.env.set(name, "runtime-test-secret");
  Deno.env.set("SUPABASE_URL", "https://supabase.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "runtime-test-service-key");
  // Deliberately keep the provider-event readiness interlock disabled.
  Deno.env.set("HENVALT_V2_MAILERSEND_EVENTS_READY", "false");

  let captured: Handler | undefined;
  const originalServe = Deno.serve;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (handler: Handler) => { captured = handler; },
  });
  try {
    await import(modulePath);
  } finally {
    Object.defineProperty(Deno, "serve", {
      configurable: true,
      value: originalServe,
    });
  }
  assert(captured, `Edge handler was not registered for ${prefix}`);
  return captured;
}

Deno.test("checkout delivery rejects missing and incorrect bearer before parsing or network", async () => {
  const handler = await loadHandler("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts", "checkout");
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("unexpected outbound request in no-send runtime test");
  }) as typeof fetch;
  try {
    const missing = await handler(new Request("https://edge.invalid", {
      method: "POST", headers: { "content-type": "application/json" }, body: "{",
    }));
    assertEquals(missing.status, 401);
    assertEquals(await missing.json(), { error: "unauthorized" });

    const incorrect = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { authorization: "Bearer wrong-secret", "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(incorrect.status, 401);
    assertEquals(await incorrect.json(), { error: "unauthorized" });
    assertEquals(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("checkout delivery readiness interlock rejects authenticated request before parsing or network", async () => {
  const handler = await loadHandler("../supabase/functions/henvalt-shopify-contact-delivery-v2/index.ts", "checkout");
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("unexpected outbound request in no-send runtime test");
  }) as typeof fetch;
  try {
    const response = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { authorization: "Bearer runtime-test-secret", "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "v2_provider_event_path_not_ready" });
    assertEquals(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("pixel delivery rejects missing and incorrect bearer before parsing or network", async () => {
  const handler = await loadHandler("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts", "pixel");
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("unexpected outbound request in no-send runtime test");
  }) as typeof fetch;
  try {
    const missing = await handler(new Request("https://edge.invalid", {
      method: "POST", headers: { "content-type": "application/json" }, body: "{",
    }));
    assertEquals(missing.status, 401);
    assertEquals(await missing.json(), { error: "unauthorized" });

    const incorrect = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { authorization: "Bearer wrong-secret", "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(incorrect.status, 401);
    assertEquals(await incorrect.json(), { error: "unauthorized" });
    assertEquals(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("pixel delivery readiness interlock rejects authenticated request before parsing or network", async () => {
  const handler = await loadHandler("../supabase/functions/henvalt-shopify-pixel-delivery-v2/index.ts", "pixel");
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("unexpected outbound request in no-send runtime test");
  }) as typeof fetch;
  try {
    const response = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { authorization: "Bearer runtime-test-secret", "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "v2_provider_event_path_not_ready" });
    assertEquals(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
