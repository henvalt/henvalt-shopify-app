export const SHOPIFY_WEBHOOK_SPECS = Object.freeze([
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
]);

export function verifyWebhookDestination(nodes, topic, expectedUri) {
  const matches = Array.isArray(nodes) ? nodes.filter((node) => node?.topic === topic) : [];
  if (matches.length === 0) return { verified: false, reason: "WEBHOOK_SUBSCRIPTION_MISSING", id: null };
  if (matches.length > 1) return { verified: false, reason: "DUPLICATE_WEBHOOK_SUBSCRIPTIONS", id: null };
  if (matches[0]?.uri !== expectedUri) return { verified: false, reason: "WEBHOOK_DESTINATION_MISMATCH", id: null };
  if (typeof matches[0]?.id !== "string" || !matches[0].id) return { verified: false, reason: "WEBHOOK_SUBSCRIPTION_ID_MISSING", id: null };
  return { verified: true, id: matches[0].id };
}
