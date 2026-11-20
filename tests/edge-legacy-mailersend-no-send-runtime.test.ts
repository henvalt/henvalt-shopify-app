import { assertEquals, assert } from "jsr:@std/assert@1";

type Handler = (request: Request) => Response | Promise<Response>;

Deno.env.set("SUPABASE_URL", "https://supabase.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "legacy-v1-runtime-test-service-key");
Deno.env.delete("HENVALT_V1_MAILERSEND_SEND_READY");

let captured: Handler | undefined;
const originalServe = Deno.serve;
Object.defineProperty(Deno, "serve", {
  configurable: true,
  value: (handler: Handler) => { captured = handler; },
});
try {
  await import("../supabase/functions/henvalt-mailersend-delivery/index.ts");
} finally {
  Object.defineProperty(Deno, "serve", { configurable: true, value: originalServe });
}
assert(captured, "Legacy V1 MailerSend handler was not registered");

Deno.test("legacy V1 MailerSend sender fails closed before parsing or outbound requests", async () => {
  const originalFetch = globalThis.fetch;
  let outboundCalls = 0;
  globalThis.fetch = async () => {
    outboundCalls++;
    throw new Error("outbound network access is forbidden in no-send acceptance");
  };

  try {
    const handler = captured!;
    const unauthorized = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(unauthorized.status, 401);
    assertEquals(await unauthorized.json(), { error: "service_role_required" });

    const request = () => new Request("https://edge.invalid", {
      method: "POST",
      headers: {
        authorization: "Bearer legacy-v1-runtime-test-service-key",
        "content-type": "application/json",
      },
      // Deliberately malformed: the disabled interlock must run before body parsing.
      body: "{",
    });

    // Missing flag is the default no-send state.
    const missingFlag = await handler(request());
    assertEquals(missingFlag.status, 503);
    assertEquals(await missingFlag.json(), { error: "delivery_send_disabled" });

    Deno.env.set("HENVALT_V1_MAILERSEND_SEND_READY", "false");
    const explicitFalse = await handler(request());
    assertEquals(explicitFalse.status, 503);
    assertEquals(await explicitFalse.json(), { error: "delivery_send_disabled" });

    // Explicit enable passes the interlock but malformed identity still fails closed.
    Deno.env.set("HENVALT_V1_MAILERSEND_SEND_READY", "true");
    const enabledButInvalid = await handler(request());
    assertEquals(enabledButInvalid.status, 400);
    assertEquals(await enabledButInvalid.json(), { error: "invalid_delivery_identity" });
    assertEquals(outboundCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
