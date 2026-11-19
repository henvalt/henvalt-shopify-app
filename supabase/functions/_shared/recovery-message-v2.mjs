const TYPES = new Set(["ABANDONED_CHECKOUT", "ABANDONED_CART", "BROWSE_ABANDONMENT"]);

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[char]);
}

function safeBrand(value) {
  if (typeof value !== "string") return "Our store";
  const normalized = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  return normalized ? normalized.slice(0, 80) : "Our store";
}

function safeStoreUrl(shopDomain) {
  if (typeof shopDomain !== "string" ||
      !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.myshopify\.com$/.test(shopDomain)) {
    throw new TypeError("A verified Shopify store domain is required");
  }
  const url = new URL("https://" + shopDomain + "/");
  if (url.protocol !== "https:" || url.hostname !== shopDomain || url.username || url.password) {
    throw new TypeError("Invalid Shopify store URL");
  }
  return url.toString();
}

/**
 * Render a deliberately minimal recovery email from server-resolved,
 * non-PII context. The MailerSend unsubscribe placeholder is mandatory.
 * No customer name, product title, cart contents, discount or checkout token
 * is accepted from the caller.
 */
export function renderRecoveryMessageV2({ shopDomain, opportunityType, brandName }) {
  if (!TYPES.has(opportunityType)) throw new TypeError("Unsupported recovery opportunity type");
  const brand = safeBrand(brandName);
  const storeUrl = safeStoreUrl(shopDomain);
  const copy = {
    ABANDONED_CHECKOUT: {
      subject: "Still thinking it over?",
      heading: "Your store is here when you're ready",
      body: `You recently started a checkout at ${brand}. If you would still like to shop, you can visit the store whenever it suits you.`,
      cta: "Visit the store",
    },
    ABANDONED_CART: {
      subject: "Something caught your eye?",
      heading: "Your store is here when you're ready",
      body: `You recently added something to your cart at ${brand}. You can revisit the store whenever you're ready.`,
      cta: "Visit the store",
    },
    BROWSE_ABANDONMENT: {
      subject: "Still interested?",
      heading: "Take another look",
      body: `You recently browsed ${brand}. If you would like to explore again, the store is ready when you are.`,
      cta: "Visit the store",
    },
  }[opportunityType];

  const escapedBrand = escapeHtml(brand);
  const escapedHeading = escapeHtml(copy.heading);
  const escapedBody = escapeHtml(copy.body);
  const escapedCta = escapeHtml(copy.cta);
  const escapedUrl = escapeHtml(storeUrl);
  const html = [
    '<!doctype html><html lang="en"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width,initial-scale=1"></head>',
    '<body style="margin:0;padding:32px 16px;background:#f7f7f7;font-family:Arial,Helvetica,sans-serif;color:#171717">',
    '<main style="max-width:560px;margin:0 auto;padding:36px 28px;background:#fff;border:1px solid #e8e8e8">',
    `<p style="margin:0 0 24px;font-size:13px;letter-spacing:.04em;color:#666">${escapedBrand}</p>`,
    `<h1 style="margin:0 0 16px;font-size:26px;line-height:1.25;font-weight:600">${escapedHeading}</h1>`,
    `<p style="margin:0 0 28px;font-size:16px;line-height:1.6;color:#444">${escapedBody}</p>`,
    `<p style="margin:0 0 32px"><a href="${escapedUrl}" style="display:inline-block;padding:13px 20px;background:#171717;color:#fff;text-decoration:none;font-size:14px;font-weight:600">${escapedCta}</a></p>`,
    '<p style="margin:0;padding-top:20px;border-top:1px solid #eee;font-size:12px;line-height:1.6;color:#777">',
    'You are receiving this message because you subscribed to marketing emails from this store. ',
    '<a href="{{unsubscribe}}" style="color:#555">Unsubscribe</a>.</p>',
    '</main></body></html>',
  ].join("");
  const text = [
    copy.heading,
    "",
    copy.body,
    "",
    copy.cta + ": " + storeUrl,
    "",
    "You are receiving this message because you subscribed to marketing emails from this store.",
    "Unsubscribe: {{unsubscribe}}",
  ].join("\n");

  return Object.freeze({ subject: copy.subject, html, text, storeUrl, templateVersion: "recovery-v2-2026-11-19" });
}

/**
 * Verify the exact sender domain's unsubscribe settings AND the active V2
 * signed webhook registration before any recovery submission. The operator
 * readiness flag is checked separately by each Edge Function; this API
 * preflight verifies that the account currently points this domain to the
 * expected V2 endpoint with every event needed for reconciliation/suppression.
 */
export async function mailerSendV2DeliveryReady(apiToken, senderEmail, providerAccountKey, supabaseUrl, fetcher = fetch) {
  if (typeof apiToken !== "string" || apiToken.length < 20 ||
      typeof senderEmail !== "string" || !/^[^\s@<>]+@[^\s@<>]+$/.test(senderEmail) ||
      typeof providerAccountKey !== "string" || !/^[A-Za-z0-9_-]{24,96}$/.test(providerAccountKey) ||
      typeof supabaseUrl !== "string") return false;

  const senderDomain = senderEmail.slice(senderEmail.lastIndexOf("@") + 1).toLowerCase();
  if (!/^[a-z0-9.-]+$/.test(senderDomain) || senderDomain.startsWith(".") || senderDomain.endsWith(".")) return false;

  let expectedWebhookUrl;
  try {
    const base = new URL(supabaseUrl);
    if (base.protocol !== "https:" || base.username || base.password ||
        base.pathname !== "/" || base.search || base.hash) return false;
    expectedWebhookUrl = base.origin + "/functions/v1/henvalt-mailersend-webhook-v2/" +
      encodeURIComponent(providerAccountKey);
  } catch {
    return false;
  }

  const headers = { authorization: "Bearer " + apiToken, accept: "application/json" };
  let domainsResponse;
  try {
    domainsResponse = await fetcher("https://api.mailersend.com/v1/domains?limit=100", {
      method: "GET", headers, signal: AbortSignal.timeout(8000),
    });
  } catch {
    return false;
  }
  if (!domainsResponse?.ok) return false;
  let domainsPayload;
  try { domainsPayload = await domainsResponse.json(); } catch { return false; }
  if (!Array.isArray(domainsPayload?.data)) return false;
  const domain = domainsPayload.data.find((entry) =>
    typeof entry?.name === "string" && entry.name.toLowerCase() === senderDomain
  );
  const settings = domain?.domain_settings;
  if (typeof domain?.id !== "string" || domain.is_verified !== true ||
      settings?.track_unsubscribe !== true ||
      settings?.track_unsubscribe_html_enabled !== true ||
      settings?.track_unsubscribe_plain_enabled !== true) return false;

  let webhooksResponse;
  try {
    const query = new URLSearchParams({ domain_id: domain.id, limit: "100" });
    webhooksResponse = await fetcher("https://api.mailersend.com/v1/webhooks?" + query.toString(), {
      method: "GET", headers, signal: AbortSignal.timeout(8000),
    });
  } catch {
    return false;
  }
  if (!webhooksResponse?.ok) return false;
  let webhooksPayload;
  try { webhooksPayload = await webhooksResponse.json(); } catch { return false; }
  if (!Array.isArray(webhooksPayload?.data)) return false;

  const requiredEvents = [
    "activity.sent",
    "activity.delivered",
    "activity.soft_bounced",
    "activity.hard_bounced",
    "activity.unsubscribed",
    "activity.spam_complaint",
    "activity.opened",
    "activity.clicked",
  ];
  return webhooksPayload.data.some((webhook) =>
    webhook?.enabled === true &&
    webhook?.version === 2 &&
    webhook?.url === expectedWebhookUrl &&
    Array.isArray(webhook?.events) &&
    requiredEvents.every((event) => webhook.events.includes(event))
  );
}
