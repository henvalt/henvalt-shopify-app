import { assertEquals } from "jsr:@std/assert";
import { getShopifyShopId, registerShopifyWebhooks, SHOPIFY_WEBHOOK_SPECS } from "./webhook-registration.ts";

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
    if (body.query.includes("webhookSubscriptions")) return response({ data: { webhookSubscriptions: { nodes: final, pageInfo: { hasNextPage: false, endCursor: null } } } });
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
    return response({ data: { webhookSubscriptions: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } });
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
      return response({ data: { webhookSubscriptions: { nodes: calls.length === 1 ? [] : [subscription(0)], pageInfo: { hasNextPage: false, endCursor: null } } } });
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
    if (body.query.includes("webhookSubscriptions")) return response({ data: { webhookSubscriptions: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } });
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

Deno.test("resolves the Shopify shop ID through the GraphQL Admin API", async () => {
  let requestedUrl = "";
  let requestedBody: any = null;
  const fetchImpl: typeof fetch = async (input, init) => {
    requestedUrl = String(input);
    requestedBody = JSON.parse(String(init?.body));
    return response({ data: { shop: { id: "gid://shopify/Shop/123" } } });
  };
  const id = await getShopifyShopId({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    fetchImpl,
  });
  assertEquals(id, "gid://shopify/Shop/123");
  assertEquals(requestedUrl, "https://demo.myshopify.com/admin/api/2026-10/graphql.json");
  assertEquals(requestedBody.query, "query { shop { id } }");
});

Deno.test("rejects GraphQL shop lookup errors and missing shop IDs", async () => {
  const graphErrorFetch: typeof fetch = async () => response({ errors: [{ message: "denied" }] });
  const missingIdFetch: typeof fetch = async () => response({ data: { shop: { id: null } } });
  let graphError = false;
  let missingId = false;
  try {
    await getShopifyShopId({ shop: "demo.myshopify.com", accessToken: "test-token", fetchImpl: graphErrorFetch });
  } catch { graphError = true; }
  try {
    await getShopifyShopId({ shop: "demo.myshopify.com", accessToken: "test-token", fetchImpl: missingIdFetch });
  } catch { missingId = true; }
  assertEquals(graphError, true);
  assertEquals(missingId, true);
});

Deno.test("paginates the subscription inventory before creating missing hooks", async () => {
  const calls: Array<{ after: string | null; query: string }> = [];
  const pageOne = Array.from({ length: 100 }, (_, i) => ({
    id: `gid://shopify/WebhookSubscription/${i + 1}`,
    topic: "UNRELATED_TOPIC",
    uri: "https://other.example/webhook",
  }));
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    if (!body.query.includes("webhookSubscriptions")) {
      const spec = SHOPIFY_WEBHOOK_SPECS.find((item) => item.gql === body.variables.topic)!;
      return response({ data: { webhookSubscriptionCreate: { userErrors: [], webhookSubscription: { id: `created-${spec.gql}` } } } });
    }
    calls.push({ after: body.variables.after ?? null, query: body.query });
    if (calls.length === 1 || calls.length === 3) {
      return response({ data: { webhookSubscriptions: { nodes: pageOne, pageInfo: { hasNextPage: true, endCursor: "cursor-100" } } } });
    }
    return response({ data: { webhookSubscriptions: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(calls.length, 4); // two pages for initial inventory, two pages for final verification
  assertEquals(calls[0].after, null);
  assertEquals(calls[1].after, "cursor-100");
  assertEquals(calls[2].after, null);
  assertEquals(calls[3].after, "cursor-100");
  assertEquals(result.allRegistered, false); // final inventory deliberately omits the created subscriptions
});

Deno.test("fails closed on a repeated pagination cursor", async () => {
  let createCount = 0;
  const fetchImpl: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body));
    if (!body.query.includes("webhookSubscriptions")) {
      createCount++;
      return response({ data: { webhookSubscriptionCreate: { userErrors: [], webhookSubscription: { id: "created" } } } });
    }
    return response({ data: { webhookSubscriptions: { nodes: [], pageInfo: { hasNextPage: true, endCursor: "same-cursor" } } } });
  };
  const result = await registerShopifyWebhooks({
    shop: "demo.myshopify.com",
    accessToken: "test-token",
    webhookUri: "https://ingress.example/webhooks",
    fetchImpl,
  });
  assertEquals(createCount, 0);
  assertEquals(result.allRegistered, false);
  assertEquals(result.results.every((item) => !item.ok), true);
});
