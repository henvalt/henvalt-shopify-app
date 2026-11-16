import test from "node:test";
import assert from "node:assert/strict";

// Synthetic contract harness only. This deliberately models the required
// isolation rules; it does not call production Supabase RPCs or use merchant data.
const fixture = {
  tenantId: "tenant-shared",
  connections: [
    { id: "connection-a", appKey: "legacy", shop: "store-a.myshopify.com", active: true },
    { id: "connection-b", appKey: "public_v1", shop: "store-b.myshopify.com", active: true },
  ],
  customers: [
    { id: "customer-a", connectionId: "connection-a", externalId: "shopify-customer-77", email: "shared@example.test" },
    { id: "customer-b", connectionId: "connection-b", externalId: "shopify-customer-77", email: "shared@example.test" },
  ],
  opportunities: [
    { id: "opportunity-a", connectionId: "connection-a", customerId: "customer-a", session: "same-session" },
    { id: "opportunity-b", connectionId: "connection-b", customerId: "customer-b", session: "same-session" },
  ],
  orders: [
    { id: "order-b", connectionId: "connection-b", customerId: "customer-b", checkoutId: "checkout-shared", placedAfter: true },
  ],
};

function normalizeShop(shop) {
  return String(shop).trim().toLowerCase().replace(/^https?:\\/\\//, "").replace(/\\/$/, "");
}

function resolveConnection(connections, appKey, shop) {
  const matches = connections.filter((item) =>
    item.active && item.appKey === appKey && normalizeShop(item.shop) === normalizeShop(shop)
  );
  if (matches.length !== 1) throw new Error(matches.length ? "AMBIGUOUS_CONNECTION" : "CONNECTION_NOT_FOUND");
  return matches[0];
}

function scopedCustomerKey(connectionId, externalId) {
  return `${connectionId}:${externalId}`;
}

function sameConnection(left, right) {
  return Boolean(left?.connectionId && right?.connectionId && left.connectionId === right.connectionId);
}

function shouldStopSequence(opportunity, order) {
  return sameConnection(opportunity, order) &&
    opportunity.customerId === order.customerId &&
    order.placedAfter;
}

function canAttributeRecovery(order, opportunity) {
  return sameConnection(order, opportunity) &&
    order.customerId === opportunity.customerId;
}

function suppressionApplies(suppression, target) {
  return suppression.connectionId === target.connectionId &&
    suppression.customerId === target.customerId;
}

test("same tenant can resolve two distinct shops only through exact app+shop tuple", () => {
  assert.equal(resolveConnection(fixture.connections, "legacy", "STORE-A.myshopify.com").id, "connection-a");
  assert.equal(resolveConnection(fixture.connections, "public_v1", "store-b.myshopify.com").id, "connection-b");
});

test("unknown app key and cross-app shop lookup fail closed", () => {
  assert.throws(() => resolveConnection(fixture.connections, "unknown", "store-a.myshopify.com"), /CONNECTION_NOT_FOUND/);
  assert.throws(() => resolveConnection(fixture.connections, "public_v1", "store-a.myshopify.com"), /CONNECTION_NOT_FOUND/);
});

test("ambiguous app+shop resolution is rejected rather than selecting an arbitrary row", () => {
  const ambiguous = [...fixture.connections, { ...fixture.connections[0], id: "duplicate-a" }];
  assert.throws(() => resolveConnection(ambiguous, "legacy", "store-a.myshopify.com"), /AMBIGUOUS_CONNECTION/);
});

test("identical Shopify customer IDs and emails remain distinct across stores", () => {
  const keys = fixture.customers.map((customer) => scopedCustomerKey(customer.connectionId, customer.externalId));
  assert.equal(new Set(keys).size, 2);
  assert.notEqual(fixture.customers[0].id, fixture.customers[1].id);
});

test("an order in Store B cannot stop Store A recovery even for same customer/session values", () => {
  const storeAOpportunity = fixture.opportunities[0];
  const storeBOrder = { ...fixture.orders[0], session: "same-session" };
  assert.equal(shouldStopSequence(storeAOpportunity, storeBOrder), false);
});

test("cross-store order cannot receive Store A recovery attribution", () => {
  assert.equal(canAttributeRecovery(fixture.orders[0], fixture.opportunities[0]), false);
});

test("store-scoped opt-out does not suppress the other store by default", () => {
  const suppressionA = { connectionId: "connection-a", customerId: "customer-a" };
  assert.equal(suppressionApplies(suppressionA, { connectionId: "connection-a", customerId: "customer-a" }), true);
  assert.equal(suppressionApplies(suppressionA, { connectionId: "connection-b", customerId: "customer-b" }), false);
});

test("missing connection lineage fails closed for attribution and suppression", () => {
  assert.equal(canAttributeRecovery({ customerId: "customer-a" }, fixture.opportunities[0]), false);
  assert.equal(suppressionApplies({ customerId: "customer-a" }, { customerId: "customer-a" }), false);
});
