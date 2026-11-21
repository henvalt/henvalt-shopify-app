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
