const body = $json.body || {};
const headers = $json.headers || {};
const query = $json.query || {};
const h = (n) => headers[n] ?? headers[n.toLowerCase()] ?? headers[n.toUpperCase()];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const shopDomain = h("x-shopify-shop-domain") || body.shop_domain || (body.commerce && body.commerce.shop_domain) || null;
const shopifyTopic = h("x-shopify-topic") || null;
const shopifyWebhookId = h("x-shopify-webhook-id") || null;
const shopifyEventId = h("x-shopify-event-id") || null;
const shopifyApiVersion = h("x-shopify-api-version") || null;
const shopifyTriggeredAt = h("x-shopify-triggered-at") || null;
const hmac = h("x-shopify-hmac-sha256") || null;
const rawBodyBase64 = ($input.item.binary && $input.item.binary.data && $input.item.binary.data.data) ? $input.item.binary.data.data : null;

const source = (shopDomain || shopifyTopic) ? "shopify" : (body.source || "internal");
const eventId = source === "shopify" ? shopifyWebhookId : (body.event_id || body.id || null);
const eventType = source === "shopify" ? shopifyTopic : (body.event_type || body.type || null);
const occurredAt = body.occurred_at || body.updated_at || body.created_at || body.email_marketing_consent?.consent_updated_at || shopifyTriggeredAt || new Date().toISOString();

// Tenant identity signal only (shop domain). Never trusted as a tenant_id.
const tenantReference = source === "shopify" ? shopDomain : (body.tenant_reference || null);

// tenant_id is NEVER invented or hard-coded. It must arrive explicitly as a UUID
// (body.tenant_id or ?tenant_id= on the webhook URL registered for that shop).
const tenantRaw = body.tenant_id || query.tenant_id || null;
const tenantId = tenantRaw && UUID_RE.test(String(tenantRaw)) ? String(tenantRaw) : null;

// correlation_id must be a UUID for the downstream RPCs.
const uuidv4 = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
  const r = (Math.random() * 16) | 0;
  return (c === "x" ? r : ((r & 0x3) | 0x8)).toString(16);
});
const correlationId = body.correlation_id && UUID_RE.test(String(body.correlation_id)) ? String(body.correlation_id) : uuidv4();

const missing = [];
if (!eventId) missing.push(source === "shopify" ? "x-shopify-webhook-id" : "event_id");
if (!eventType) missing.push("event_type");
if (!source) missing.push("source");
if (!tenantReference) missing.push("tenant_reference");
if (!occurredAt) missing.push("occurred_at");
if (!tenantId && source !== "shopify") missing.push("tenant_id");

const customer = body.customer || {};
const commerce = body.commerce || {};
const shippingAddress = body.shipping_address || body.shippingAddress || {};
const billingAddress = body.billing_address || body.billingAddress || {};
const customerAddress = customer.default_address || customer.defaultAddress || {};
const countryCode = String(
  shippingAddress.country_code || shippingAddress.countryCode ||
  billingAddress.country_code || billingAddress.countryCode ||
  customerAddress.country_code || customerAddress.countryCode || ""
).trim().toUpperCase() || null;
const countryCodeSource = countryCode
  ? (shippingAddress.country_code || shippingAddress.countryCode ? "checkout_shipping_address"
    : billingAddress.country_code || billingAddress.countryCode ? "checkout_billing_address"
    : "customer_default_address")
  : "unavailable";
const topicLower = String(eventType || "").toLowerCase();
const isCustomerConsentUpdate = topicLower === "customers/email_marketing_consent/update" || topicLower === "customers_email_marketing_consent/update" || topicLower === "customers_email_marketing_consent_update" || topicLower === "customers_email_marketing_consent_update";
const isCheckoutTopic = topicLower.includes("checkout");
const isCartTopic = topicLower.includes("cart");
const isCheckoutOrCartTopic = isCheckoutTopic || isCartTopic;
const cartItems = Array.isArray(body.line_items) ? body.line_items : [];
const cartPath = cartItems.map((item) => {
  const variantId = String((item && item.variant_id) ?? "");
  const quantity = Number((item && item.quantity) ?? 0);
  return /^\d+$/.test(variantId) && Number.isInteger(quantity) && quantity > 0 ? variantId + ":" + quantity : null;
}).filter(Boolean).join(",");
const cartDestination = isCartTopic && shopDomain && cartPath ? "https://" + shopDomain + "/cart/" + cartPath : null;
let cartValue = 0;
for (const item of cartItems) {
  const lineTotal = Number(item.line_price || item.discounted_price || 0);
  const unitPrice = Number(item.price || item.original_price || 0);
  const quantity = Number(item.quantity || 0);
  cartValue += lineTotal > 0 ? lineTotal : unitPrice * quantity;
}
const consent = (o) => (o && o.state ? o.state === "subscribed" : null);
const consentRecord = customer.email_marketing_consent || body.email_marketing_consent || null;
const consentState = consentRecord && typeof consentRecord.state === "string" ? consentRecord.state.toLowerCase() : null;
// Shopify's checkout buyer_accepts_marketing is a checkout-level marketing choice,
// not a global unsubscribe. Only the customer marketing-consent record updates the
// stored subscription state. Preserve an existing subscribed state when this flag is false.
const checkoutConsent = typeof body.buyer_accepts_marketing === "boolean" ? body.buyer_accepts_marketing : null;
const customerConsent = typeof customer.accepts_marketing === "boolean" ? customer.accepts_marketing : null;
const emailConsent = consentState
  ? consentState === "subscribed"
  : (customerConsent !== null ? customerConsent : null);

const normalized = {
  event_id: eventId,
  event_type: eventType,
  source,
  tenant_reference: tenantReference,
  occurred_at: occurredAt,
  customer: {
    id: customer.id ?? body.customer_id ?? (isCustomerConsentUpdate ? body.id : null),
    email: customer.email ?? body.email ?? body.email_address ?? null,
    phone: customer.phone ?? body.phone ?? null,
    first_name: customer.first_name ?? null,
    last_name: customer.last_name ?? null,
    email_consent: emailConsent,
    sms_consent: consent(customer.sms_marketing_consent),
  },
  commerce: {
    shop_domain: shopDomain,
    country_code: countryCode,
    country_code_source: countryCodeSource,
    checkout_id: body.checkout_id ?? commerce.checkout_id ?? (isCheckoutTopic ? (body.id ?? body.token) : (isCartTopic ? body.id : null)) ?? null,
    checkout_token: body.token ?? commerce.checkout_token ?? null,
    cart_token: body.cart_token ?? (isCartTopic ? body.token : null) ?? null,
    cart_id: body.cart_id ?? commerce.cart_id ?? (isCartTopic ? body.id : null) ?? null,
    order_id: body.order_id ?? commerce.order_id ?? (eventType && String(eventType).indexOf("order") !== -1 ? body.id : null) ?? null,
    currency: body.currency ?? commerce.currency ?? null,
    value: Number(body.total_price ?? body.value ?? commerce.value ?? (isCartTopic ? cartValue : 0)) || 0,
    items: cartItems.slice(0, 20).map((item) => ({
      title: String(item.title || item.name || "").slice(0, 200),
      quantity: Number.isFinite(Number(item.quantity)) ? Math.max(0, Math.floor(Number(item.quantity))) : 0,
      unit_price: Number(item.price || item.original_price || 0) || 0,
      line_total: Number(item.line_price || item.discounted_price || 0) || 0,
      product_id: item.product_id == null ? null : String(item.product_id),
      variant_id: item.variant_id == null ? null : String(item.variant_id),
      sku: item.sku == null ? null : String(item.sku).slice(0, 100)
    })).filter((item) => item.title || item.product_id || item.variant_id),
  },
  destination_url: body.destination_url ?? body.abandoned_checkout_url ?? cartDestination ?? null,
  metadata: { shopify_topic: shopifyTopic, hmac_present: !!hmac, email_marketing_consent_state: consentState, email_marketing_consent_updated_at: consentRecord?.consent_updated_at ?? null, country_code: countryCode, country_code_source: countryCodeSource },
  correlation_id: correlationId,
};

const verification = { source, shop_domain: shopDomain, hmac_sha256: hmac, raw_body_base64: rawBodyBase64 };
const idempotencyKey = source === "shopify"
  ? ["shopify", tenantReference, shopifyWebhookId].join(":")
  : (body.idempotency_key || [source, tenantReference, eventType, eventId].join(":"));

return {
  __valid: missing.length === 0,
  __missing: missing,
  __tenant_mapping_missing: source === "shopify" ? !shopDomain : !tenantId,
  correlation_id: correlationId,
  event: normalized,
  verification,
  ingest: {
    tenant_id: tenantId,
    source,
    source_event_id: eventId == null ? null : String(eventId),
    topic: eventType,
    idempotency_key: idempotencyKey,
    payload: body,
    metadata: {
      shop_domain: shopDomain,
      shopify_webhook_id: shopifyWebhookId,
      shopify_event_id: shopifyEventId,
      shopify_topic: shopifyTopic,
      shopify_api_version: shopifyApiVersion,
      shopify_triggered_at: shopifyTriggeredAt,
      tenant_reference: tenantReference,
      verification: { source, shop_domain: shopDomain, hmac_present: !!hmac },
      correlation_id: correlationId,
      n8n_execution_id: $execution.id,
    },
    occurred_at: occurredAt,
    correlation_id: correlationId,
  },
};