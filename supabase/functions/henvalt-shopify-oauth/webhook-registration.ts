export const SHOPIFY_WEBHOOK_SPECS = [
  { topic: "orders/create", gql: "ORDERS_CREATE" },
  { topic: "orders/updated", gql: "ORDERS_UPDATED" },
  { topic: "orders/paid", gql: "ORDERS_PAID" },
  { topic: "orders/cancelled", gql: "ORDERS_CANCELLED" },
  { topic: "refunds/create", gql: "REFUNDS_CREATE" },
  { topic: "order_transactions/create", gql: "ORDER_TRANSACTIONS_CREATE" },
  { topic: "checkouts/create", gql: "CHECKOUTS_CREATE" },
  { topic: "checkouts/update", gql: "CHECKOUTS_UPDATE" },
  { topic: "carts/create", gql: "CARTS_CREATE" },
  { topic: "carts/update", gql: "CARTS_UPDATE" },
  { topic: "customers_email_marketing_consent/update", gql: "CUSTOMERS_EMAIL_MARKETING_CONSENT_UPDATE" },
  { topic: "app/uninstalled", gql: "APP_UNINSTALLED" },
] as const;

const LIST_QUERY = "query { webhookSubscriptions(first:100) { nodes { id topic uri } } }";
const CREATE_MUTATION = `mutation CreateWebhook($topic: WebhookSubscriptionTopic!, $input: WebhookSubscriptionInput!) {
  webhookSubscriptionCreate(topic:$topic,webhookSubscription:$input) {
    userErrors { message }
    webhookSubscription { id topic uri }
  }
}`;

type Subscription = { id: string; topic: string; uri: string };
type Result = { topic: string; ok: boolean; verified: boolean; id?: string; error?: string };

export async function registerShopifyWebhooks(input: {
  shop: string;
  accessToken: string;
  webhookUri: string;
  fetchImpl?: typeof fetch;
}): Promise<{ results: Result[]; allRegistered: boolean }> {
  const fetchImpl = input.fetchImpl ?? fetch;
  const endpoint = `https://${input.shop}/admin/api/2026-10/graphql.json`;
  const gql = async (query: string, variables: Record<string, unknown> = {}) => {
    const response = await fetchImpl(endpoint, {
      method: "POST",
      headers: {
        "x-shopify-access-token": input.accessToken,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.timeout(15000),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload?.errors?.length) throw new Error("SHOPIFY_GRAPHQL_REQUEST_FAILED");
    return payload?.data ?? {};
  };
  const getSubscriptions = async (): Promise<Subscription[]> => {
    const data = await gql(LIST_QUERY);
    const nodes = data?.webhookSubscriptions?.nodes;
    if (!Array.isArray(nodes)) throw new Error("SHOPIFY_WEBHOOK_LIST_INVALID");
    return nodes.filter((node: any) =>
      node && typeof node.id === "string" && typeof node.topic === "string" && typeof node.uri === "string"
    );
  };

  let initial: Subscription[] | null = null;
  let initialLookupError = false;
  try {
    initial = await getSubscriptions();
  } catch {
    // Fail closed: never create subscriptions when the existing set is unknown.
    initialLookupError = true;
  }

  const results: Result[] = [];
  for (const spec of SHOPIFY_WEBHOOK_SPECS) {
    if (initialLookupError) {
      results.push({ topic: spec.topic, ok: false, verified: false, error: "initial_lookup_failed" });
      continue;
    }
    const existing = initial!.find((node) => node.topic === spec.gql && node.uri === input.webhookUri);
    if (existing) {
      results.push({ topic: spec.topic, ok: true, verified: false });
      continue;
    }
    try {
      const data = await gql(CREATE_MUTATION, {
        topic: spec.gql,
        input: { uri: input.webhookUri, format: "JSON" },
      });
      const created = data?.webhookSubscriptionCreate;
      if (created?.userErrors?.length || !created?.webhookSubscription?.id) {
        results.push({
          topic: spec.topic,
          ok: false,
          verified: false,
          error: (created?.userErrors ?? []).map((item: any) => String(item.message ?? "user_error")).join("; ") || "not_created",
        });
      } else {
        results.push({ topic: spec.topic, ok: true, verified: false });
      }
    } catch {
      results.push({ topic: spec.topic, ok: false, verified: false, error: "registration_failed" });
    }
  }

  let finalSubscriptions: Subscription[] = [];
  let finalLookupError = false;
  try {
    finalSubscriptions = await getSubscriptions();
  } catch {
    finalLookupError = true;
  }
  for (const result of results) {
    const spec = SHOPIFY_WEBHOOK_SPECS.find((item) => item.topic === result.topic)!;
    const verified = finalSubscriptions.find((node) =>
      node.topic === spec.gql && node.uri === input.webhookUri
    );
    result.verified = Boolean(verified);
    result.ok = Boolean(verified);
    if (verified) {
      result.id = verified.id;
      delete result.error;
    } else if (finalLookupError) {
      result.error = result.error ?? "final_verification_failed";
    } else {
      result.error = result.error ?? "subscription_not_verified";
    }
  }

  return {
    results,
    allRegistered: results.length === SHOPIFY_WEBHOOK_SPECS.length &&
      results.every((item) => item.ok && item.verified),
  };
}
