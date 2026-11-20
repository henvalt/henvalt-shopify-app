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
    const validPayload = {
      tenant_id: "11111111-1111-4111-8111-111111111111",
      delivery_request_id: "22222222-2222-4222-8222-222222222222",
      to: "recipient@example.invalid",
      from_email: "sender@example.invalid",
      from_name: "HENVALT Test",
      subject: "No-send acceptance fixture",
      text_body: "This fixture must never be sent.",
    };
    const request = (body: string) => new Request("https://edge.invalid", {
      method: "POST",
      headers: {
        authorization: "Bearer legacy-v1-runtime-test-service-key",
        "content-type": "application/json",
      },
      body,
    });

    // Authentication is checked before body parsing.
    const unauthorized = await handler(new Request("https://edge.invalid", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{",
    }));
    assertEquals(unauthorized.status, 401);
    assertEquals(await unauthorized.json(), { error: "service_role_required" });

    // Unsupported methods cannot reach parsing, credentials, or the provider.
    const unsupportedMethod = await handler(new Request("https://edge.invalid", {
      method: "GET",
    }));
    assertEquals(unsupportedMethod.status, 405);
    assertEquals(await unsupportedMethod.json(), { error: "method_not_allowed" });

    // CORS preflight is handled without invoking the sender transport.
    const preflight = await handler(new Request("https://edge.invalid", {
      method: "OPTIONS",
    }));
    assertEquals(preflight.status, 204);
    assertEquals(preflight.headers.get("access-control-allow-methods"), "POST, OPTIONS");

    // Missing readiness flag is the default no-send state, even for a valid request.
    const missingFlag = await handler(request(JSON.stringify(validPayload)));
    assertEquals(missingFlag.status, 503);
    assertEquals(await missingFlag.json(), { error: "delivery_send_disabled" });

    // Explicit false also blocks a valid request before any outbound call.
    Deno.env.set("HENVALT_V1_MAILERSEND_SEND_READY", "false");
    const explicitFalse = await handler(request(JSON.stringify(validPayload)));
    assertEquals(explicitFalse.status, 503);
    assertEquals(await explicitFalse.json(), { error: "delivery_send_disabled" });

    // The disabled gate also precedes parsing: malformed JSON cannot reach parsing while disabled.
    const malformedWhileDisabled = await handler(request("{"));
    assertEquals(malformedWhileDisabled.status, 503);
    assertEquals(await malformedWhileDisabled.json(), { error: "delivery_send_disabled" });

    // Exact "true" opens the interlock, but invalid input still fails before any outbound request.
    Deno.env.set("HENVALT_V1_MAILERSEND_SEND_READY", "true");
    const enabledButInvalid = await handler(request("{"));
    assertEquals(enabledButInvalid.status, 400);
    assertEquals(await enabledButInvalid.json(), { error: "invalid_delivery_identity" });

    assertEquals(outboundCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
    Deno.env.delete("HENVALT_V1_MAILERSEND_SEND_READY");
  }
});
