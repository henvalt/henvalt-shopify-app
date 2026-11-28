import test from "node:test";
import assert from "node:assert/strict";
import {
  createGroqGenerationHandler,
  GROQ_CHAT_COMPLETIONS_URL,
  STAGING_SUPABASE_URL,
} from "../supabase/functions/henvalt-groq-generate/handler.mjs";

const serviceRoleKey = "test-service-role-key";
const groqApiKey = "test-groq-api-key-123456789012345";
const validPayload = {
  model: "openai/gpt-oss-120b",
  temperature: 0.3,
  response_format: { type: "json_object" },
  messages: [
    { role: "system", content: "Write valid JSON only." },
    { role: "user", content: "Create a short recovery email." },
  ],
};
const makeRequest = (payload = validPayload, token = serviceRoleKey, method = "POST") =>
  new Request("https://worker.test/functions/v1/henvalt-groq-generate", {
    method,
    headers: token ? { authorization: `Bearer ${token}`, "content-type": "application/json" } : {},
    body: method === "POST" ? JSON.stringify(payload) : undefined,
  });

function handler(overrides = {}) {
  return createGroqGenerationHandler({
    supabaseUrl: STAGING_SUPABASE_URL,
    serviceRoleKey,
    groqApiKey,
    fetchImpl: async () => new Response(JSON.stringify({
      choices: [{ message: { role: "assistant", content: JSON.stringify({
        subject: "A note for you",
        opening: "Hi there,",
        body: "Your checkout is ready whenever you are.",
        cta_text: "Return to checkout",
      }) } }],
    }), { status: 200, headers: { "content-type": "application/json" } }),
    ...overrides,
  });
}

test("rejects non-POST methods without contacting the provider", async () => {
  let calls = 0;
  const result = await handler({ fetchImpl: async () => { calls++; throw new Error("unexpected"); } })(makeRequest(validPayload, serviceRoleKey, "GET"));
  assert.equal(result.status, 405);
  assert.equal(calls, 0);
});

test("requires the exact service-role bearer before provider access", async () => {
  let calls = 0;
  const run = handler({ fetchImpl: async () => { calls++; throw new Error("unexpected"); } });
  for (const token of ["", "wrong-token"]) {
    const result = await run(makeRequest(validPayload, token));
    assert.equal(result.status, 401);
  }
  assert.equal(calls, 0);
});

test("fails closed if configured for any project other than staging", async () => {
  let calls = 0;
  const run = handler({
    supabaseUrl: "https://ocyplckdojdubyrsxcxa.supabase.co",
    fetchImpl: async () => { calls++; throw new Error("unexpected"); },
  });
  const result = await run(makeRequest());
  assert.equal(result.status, 503);
  assert.equal(calls, 0);
});

test("does not call Groq when the provider key is missing", async () => {
  let calls = 0;
  const run = handler({ groqApiKey: "", fetchImpl: async () => { calls++; throw new Error("unexpected"); } });
  const result = await run(makeRequest());
  assert.equal(result.status, 503);
  assert.equal(calls, 0);
});

test("enforces the fixed model, JSON-only contract and bounded temperature", async () => {
  const invalid = [
    { ...validPayload, model: "arbitrary-model" },
    { ...validPayload, temperature: 0.9 },
    { ...validPayload, response_format: { type: "text" } },
    { ...validPayload, messages: [{ role: "user", content: "only one message" }] },
    { ...validPayload, messages: [{ role: "system", content: "s" }, { role: "assistant", content: "a" }] },
    { ...validPayload, stream: true },
  ];
  let calls = 0;
  const run = handler({ fetchImpl: async () => { calls++; throw new Error("unexpected"); } });
  for (const payload of invalid) {
    const result = await run(makeRequest(payload));
    assert.equal(result.status, 400);
  }
  assert.equal(calls, 0);
});

test("forwards only the allowlisted request contract and returns only generated content", async () => {
  let captured;
  const run = handler({
    fetchImpl: async (url, options) => {
      captured = { url, options, body: JSON.parse(options.body) };
      return new Response(JSON.stringify({
        id: "provider-id",
        choices: [{ message: { role: "assistant", content: '{"subject":"A note","body":"Hello"}' } }],
        usage: { prompt_tokens: 999 },
      }), { status: 200 }),
    },
  });
  const result = await run(makeRequest({ ...validPayload, ignored: "not forwarded" }));
  assert.equal(result.status, 200);
  assert.equal(captured.url, GROQ_CHAT_COMPLETIONS_URL);
  assert.equal(captured.options.redirect, "error");
  assert.equal(captured.options.headers.authorization, `Bearer ${groqApiKey}`);
  assert.deepEqual(captured.body, {
    model: validPayload.model,
    temperature: validPayload.temperature,
    response_format: { type: "json_object" },
    messages: validPayload.messages,
    stream: false,
  });
  const response = await result.json();
  assert.deepEqual(response, {
    choices: [{ message: { role: "assistant", content: '{"subject":"A note","body":"Hello"}' } }],
    model: validPayload.model,
  });
  assert.equal(JSON.stringify(response).includes("provider-id"), false);
});

test("does not expose upstream error bodies or provider credentials", async () => {
  const run = handler({
    fetchImpl: async () => new Response("private provider diagnostic and secret-like data", { status: 429 }),
  });
  const result = await run(makeRequest());
  assert.equal(result.status, 502);
  const response = await result.text();
  assert.equal(response.includes("private provider diagnostic"), false);
  assert.equal(response.includes(groqApiKey), false);
});

test("rejects malformed or oversized provider output", async () => {
  for (const payload of [
    { choices: [] },
    { choices: [{ message: { content: "" } }] },
    { choices: [{ message: { content: "x".repeat(12001) } }] },
  ]) {
    const run = handler({ fetchImpl: async () => new Response(JSON.stringify(payload), { status: 200 }) });
    const result = await run(makeRequest());
    assert.equal(result.status, 502);
  }
});
