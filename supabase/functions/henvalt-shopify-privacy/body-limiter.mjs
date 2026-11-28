/**
 * Read a request body incrementally and stop as soon as it exceeds the byte cap.
 * This avoids buffering arbitrarily large unauthenticated webhook bodies in memory.
 *
 * @param {Request} req
 * @param {number} maxBytes
 * @returns {Promise<{ok:true,bytes:Uint8Array}|{ok:false,reason:"too_large"}>}
 */
export async function readBoundedBody(req, maxBytes) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new RangeError("maxBytes must be a non-negative safe integer");
  }

  const declaredLength = req.headers.get("content-length");
  if (declaredLength !== null) {
    const parsedLength = Number(declaredLength);
    if (Number.isSafeInteger(parsedLength) && parsedLength >= 0 && parsedLength > maxBytes) {
      try { await req.body?.cancel("payload_too_large"); } catch { /* best-effort stream cancellation */ }
      return { ok: false, reason: "too_large" };
    }
  }

  if (!req.body) return { ok: true, bytes: new Uint8Array() };

  const reader = req.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  let tooLarge = false;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) {
        throw new TypeError("request body stream must yield Uint8Array chunks");
      }
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        tooLarge = true;
        try { await reader.cancel("payload_too_large"); } catch { /* best-effort stream cancellation */ }
        break;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  if (tooLarge) return { ok: false, reason: "too_large" };

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, bytes };
}
