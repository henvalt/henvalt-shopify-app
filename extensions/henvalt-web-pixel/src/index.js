import { register } from "@shopify/web-pixels-extension";

const ALLOWED_EVENTS = new Set([
  "page_viewed",
  "product_viewed",
  "product_added_to_cart",
  "checkout_started",
]);

function safePageUrl(raw) {
  try {
    const url = new URL(raw);
    // Do not forward query strings or fragments, which can contain personal data.
    return url.origin + url.pathname.slice(0, 1000);
  } catch {
    return null;
  }
}

function asString(value, max = 200) {
  return typeof value === "string" ? value.slice(0, max) : null;
}

function idString(value, max = 100) {
  return value == null ? null : asString(String(value), max);
}

register(({ analytics, settings }) => {
  const collectorUrl = asString(settings.collectorUrl, 500);
  const publicKey = asString(settings.publicKey, 300);

  // A pixel without tenant-scoped collector credentials is intentionally inert.
  if (!collectorUrl || !publicKey || !collectorUrl.startsWith("https://")) return;

  for (const eventName of ALLOWED_EVENTS) {
    analytics.subscribe(eventName, (event) => {
      const data = event?.data ?? {};
      const cartLine = data.cartLine ?? null;
      const merchandise = cartLine?.merchandise ?? null;
      const productVariant = data.productVariant ?? null;
      const product =
        merchandise?.product ??
        productVariant?.product ??
        data.product ??
        null;
      const variant = merchandise ?? productVariant ?? data.variant ?? null;
      const checkout = data.checkout ?? null;

      const payload = {
        schema_version: 1,
        event_id: asString(event?.id, 160),
        event_type: eventName,
        occurred_at: asString(event?.timestamp, 80),
        // client_id is an anonymous browser/session reference, never a customer identity.
        client_id: asString(event?.clientId, 160),
        page_url: safePageUrl(event?.context?.document?.location?.href ?? ""),
        product: product ? {
          id: idString(product.id),
          title: asString(product.title, 200),
          variant_id: idString(variant?.id),
        } : null,
        cart_line: cartLine ? {
          quantity: Number.isFinite(Number(cartLine.quantity))
            ? Math.max(0, Math.floor(Number(cartLine.quantity)))
            : null,
          merchandise_id: idString(merchandise?.id),
        } : null,
        // Shopify checkout token is used only as a correlation alias to join
        // this anonymous browser session to a later signed checkout webhook.
        checkout_reference: eventName === "checkout_started"
          ? asString(checkout?.token, 300)
          : null,
      };

      fetch(collectorUrl, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-henvalt-pixel-key": publicKey,
        },
        body: JSON.stringify(payload),
        keepalive: true,
      }).catch(() => {
        // Storefront tracking must never disrupt checkout or page rendering.
      });
    });
  }
});
