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

function eventPayload(event, eventType, settings) {
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
    public_key: settings.publicKey,
    page_url: location,
    product: product ? {
      id: safeString(product.id, 200),
      title: safeString(product.title, 200),
      variant_id: safeString(productVariant?.id, 200),
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

export function register(analytics, settings) {
  if (!settings?.collectorUrl || !settings?.publicKey) return;

  const collector = new URL(settings.collectorUrl);
  if (collector.protocol !== "https:") return;

  for (const eventType of ALLOWED_EVENTS) {
    analytics.subscribe(eventType, (event) => {
      const payload = eventPayload(event, eventType, settings);
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
}
