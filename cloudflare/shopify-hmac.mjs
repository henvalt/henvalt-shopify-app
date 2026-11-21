/**
 * Verify Shopify's base64-encoded HMAC-SHA256 against the exact raw body bytes.
 * The caller must pass the untouched request bytes; do not JSON-parse/stringify.
 */
export async function verifyShopifyWebhookHmac(rawBody, secret, receivedHmac, cryptoProvider = globalThis.crypto) {
  if (!(rawBody instanceof Uint8Array) || typeof secret !== "string" || secret.length === 0) return false;
  if (typeof receivedHmac !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(receivedHmac)) return false;
  if (!cryptoProvider?.subtle) return false;

  const key = await cryptoProvider.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await cryptoProvider.subtle.sign("HMAC", key, rawBody));
  let binary = "";
  for (const byte of signature) binary += String.fromCharCode(byte);
  const expected = btoa(binary);
  if (expected.length !== receivedHmac.length) return false;

  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) {
    difference |= expected.charCodeAt(index) ^ receivedHmac.charCodeAt(index);
  }
  return difference === 0;
}
