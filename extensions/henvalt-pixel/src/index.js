import { register } from "@shopify/web-pixels-extension";

const ALLOWED_EVENTS = [
  "page_viewed",
  "product_viewed",
  "product_added_to_cart",
  "checkout_started",
];

function id() {
  try {
    return crypto.randomUUID();
  } catch {
    return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }
}

function safeString(value, max = 300) {
  return typeof value === "string" && value.length > 0
    ? value.slice(0, max)
    : null;
}

function safeAmount(value) {
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return String(value);
  }
  if (typeof value === "string" && value.length > 0 && value.length <= 40
      && Number.isFinite(Number(value)) && Number(value) >= 0) {
    return value;
  }
  return null;
}

function shopifyCustomerReference(value) {
  const raw = safeString(value, 200);
  if (!raw) return null;
  const gid = raw.match(/^gid:\/\/shopify\/Customer\/(\d+)$/);
  if (gid) return gid[1];
  return /^\d+$/.test(raw) ? raw : null;
}

function eventPayload(event, eventType, settings, customerReference, privacy) {
  const data = event.data || {};
  const productVariant = data.productVariant || data.product || null;
  const product = productVariant?.product || productVariant || null;
  const cartLine = data.cartLine || null;
  const merchandise = cartLine?.merchandise || cartLine?.variant || null;
  const checkout = data.checkout || null;
  const location = event.context?.document?.location?.href || null;

  return {
    schema_version: 1,
    event_id: safeString(event.id, 160) || id(),
    event_type: eventType,
    occurred_at: safeString(event.timestamp, 80) || new Date().toISOString(),
    client_id: safeString(event.clientId, 160) || id(),
    customer_reference: shopifyCustomerReference(customerReference),
    analytics_consent: privacy?.analyticsProcessingAllowed === true,
    marketing_consent: privacy?.marketingAllowed === true,
    public_key: settings.publicKey,
    page_url: location,
    product: product ? {
      id: safeString(product.id, 200),
      title: safeString(product.title, 200),
      variant_id: safeString(productVariant?.id, 200),
      price_amount: safeAmount(productVariant?.price?.amount),
      price_currency: safeString(productVariant?.price?.currencyCode, 3),
    } : null,
    cart_line: cartLine ? {
      quantity: Number.isInteger(cartLine.quantity) ? cartLine.quantity : null,
      merchandise_id: safeString(merchandise?.id, 200),
    } : null,
    checkout_reference: eventType === "checkout_started"
      ? safeString(checkout?.token || checkout?.id, 300)
      : null,
  };
}

register(({ analytics, settings, init, customerPrivacy }) => {
  if (!settings?.collectorUrl || !settings?.publicKey) return;

  const collector = new URL(settings.collectorUrl);
  if (collector.protocol !== "https:") return;

  let privacy = init?.customerPrivacy || {};
  try {
    customerPrivacy?.subscribe("visitorConsentCollected", (event) => {
      privacy = event?.customerPrivacy || privacy;
    });
  } catch {
    // Keep the initial privacy state if the consent subscription is unavailable.
  }

  for (const eventType of ALLOWED_EVENTS) {
    analytics.subscribe(eventType, (event) => {
      if (privacy?.analyticsProcessingAllowed !== true) return;
      const customerReference = init?.data?.customer?.id || null;
      const payload = eventPayload(event, eventType, settings, customerReference, privacy);
      fetch(collector.toString(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        keepalive: true,
      }).catch(() => {
        // Pixel delivery is best-effort; storefront checkout must never be blocked.
      });
    });
  }
});
