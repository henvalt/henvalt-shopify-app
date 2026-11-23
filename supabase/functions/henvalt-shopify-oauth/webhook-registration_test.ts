import { assertEquals } from "jsr:@std/assert";
import { registerShopifyWebhooks, SHOPIFY_WEBHOOK_SPECS } from "./webhook-registration.ts";

function response(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}
function subscription(i: number) {
  const spec = SHOPIFY_WEBHOOK_SPECS[i];
  return { id: `gid://shopify/WebhookSubscription/${i + 1}`, topic: spec.gql, uri: "https://ingress.example/webhooks" };
}

Deno.test("reads existing subscriptions once, creates only missing topics, and verifies the final set", async () => {
  const existing = [subscription(0), subscription(1)];
  const calls: string[] = [];
  let final = [...existing];
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    calls.push(body.query.includes("webhookSubscriptions") ? "list" : "create");
    if (body.query.includes("webhookSubscriptions")) return response({ data: { webhookSubscriptions: { nodes: final } } });
    const index = SHOPIFY_WEBHOOK_SPECS.findIndex((item) => item.gql === body.variables.topic);
    const created = subscription(index);
    final = [...final, created];
    return response({ data: { webhookSubscriptionCreate: { userErrors: [], webhookSubscription: created } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(calls.filter((call) => call === "list").length, 2);
  assertEquals(calls.filter((call) => call === "create").length, SHOPIFY_WEBHOOK_SPECS.length - 2);
  assertEquals(result.allRegistered, true);
  assertEquals(result.results.length, 12);
  assertEquals(result.results.every((item) => item.ok && item.verified && item.id), true);
});

Deno.test("fails closed when the initial subscription list is unavailable", async () => {
  const calls: string[] = [];
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    calls.push(body.query.includes("webhookSubscriptions") ? "list" : "create");
    if (calls.length === 1) return response({}, 503);
    return response({ data: { webhookSubscriptions: { nodes: [] } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(calls.filter((call) => call === "create").length, 0);
  assertEquals(result.allRegistered, false);
  assertEquals(result.results.every((item) => !item.ok), true);
});

Deno.test("uses final verification as the source of truth after a mutation user error", async () => {
  const calls: string[] = [];
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    if (body.query.includes("webhookSubscriptions")) {
      calls.push("list");
      return response({ data: { webhookSubscriptions: { nodes: calls.length === 1 ? [] : [subscription(0)] } } });
    }
    calls.push("create");
    return response({ data: { webhookSubscriptionCreate: { userErrors: [{ message: "already exists" }], webhookSubscription: null } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(result.results[0].ok, true);
  assertEquals(result.results[0].verified, true);
  assertEquals(result.results[0].id, subscription(0).id);
});

Deno.test("does not report success when final verification fails", async () => {
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    if (body.query.includes("webhookSubscriptions")) return response({ data: { webhookSubscriptions: { nodes: [] } } });
    return response({ data: { webhookSubscriptionCreate: { userErrors: [], webhookSubscription: { id: "created-id" } } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(result.allRegistered, false);
  assertEquals(result.results.every((item) => !item.ok), true);
});
