/**
 * HENVALT trusted Shopify connection identity.
 *
 * Pure validation boundary for future app-aware ingress adapters.
 * This module does not perform HMAC verification, database lookup, or
 * credential selection. Callers must pass a connection row returned by a
 * trusted server-side resolver after webhook/OAuth authentication.
 *
 * Never construct this envelope from unsigned request headers or payload
 * metadata. Missing, inactive, ambiguous, or mismatched identity fails closed.
 */

const SHOP_DOMAIN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.myshopify\.com$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const APP_KEY = /^[a-z][a-z0-9_]{1,47}$/;

export function normalizeShopDomain(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase().replace(/\.$/, "");
  return SHOP_DOMAIN.test(normalized) ? normalized : null;
}

/**
 * @param {{
 *   appKey: string,
 *   shopDomain: string,
 *   connection: {
 *     id: string,
 *     tenant_id: string,
 *     shop_domain: string,
 *     app_key: string | null,
 *     is_active?: boolean,
 *     status?: string
 *   } | null
 * }} input
 * @returns {{ok: true, identity: Readonly<{
 *   appKey: string, connectionId: string, tenantId: string, shopDomain: string
 * }>} | {ok: false, code: string}}
 */
export function resolveTrustedShopifyIdentity(input) {
  if (!input || typeof input !== "object") {
    return { ok: false, code: "IDENTITY_INPUT_MISSING" };
  }

  const { appKey, shopDomain, connection } = input;
  if (typeof appKey !== "string" || !APP_KEY.test(appKey)) {
    return { ok: false, code: "APP_KEY_INVALID" };
  }

  const normalizedShop = normalizeShopDomain(shopDomain);
  if (!normalizedShop) {
    return { ok: false, code: "SHOP_DOMAIN_INVALID" };
  }

  if (!connection || typeof connection !== "object") {
    return { ok: false, code: "SHOP_CONNECTION_NOT_FOUND" };
  }

  if (connection.active === false || connection.is_active === false ||
      connection.reauth_required_at != null || connection.status === "inactive" ||
      connection.status === "disconnected" || connection.status === "reauth_required") {
    return { ok: false, code: "SHOP_CONNECTION_INACTIVE" };
  }

  if (typeof connection.id !== "string" || !UUID.test(connection.id) ||
      typeof connection.tenant_id !== "string" || !UUID.test(connection.tenant_id)) {
    return { ok: false, code: "SHOP_CONNECTION_IDENTITY_INVALID" };
  }

  const resolvedShop = normalizeShopDomain(connection.shop_domain);
  if (!resolvedShop || resolvedShop !== normalizedShop) {
    return { ok: false, code: "SHOP_DOMAIN_MISMATCH" };
  }

  // NULL is a legacy/unclassified row, not permission to fall back to a
  // default app. It must be explicitly mapped after provenance verification.
  if (connection.app_key !== appKey) {
    return { ok: false, code: "SHOP_APP_IDENTITY_MISMATCH" };
  }

  return {
    ok: true,
    identity: Object.freeze({
      appKey,
      connectionId: connection.id,
      tenantId: connection.tenant_id,
      shopDomain: normalizedShop,
    }),
  };
}
