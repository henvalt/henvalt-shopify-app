export class RequestBodyError extends Error {
  readonly code: "BODY_TOO_LARGE" | "EMPTY_BODY" | "INVALID_CONTENT_TYPE" | "INVALID_CONTENT_LENGTH" | "INVALID_UTF8" | "INVALID_JSON" | "INVALID_OBJECT";
  constructor(code: RequestBodyError["code"]) {
    super(code);
    this.name = "RequestBodyError";
    this.code = code;
  }
}

export async function readBoundedBody(request: Request, maxBytes: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new TypeError("maxBytes must be a positive safe integer");
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    if (!/^\d+$/.test(declared)) throw new RequestBodyError("INVALID_CONTENT_LENGTH");
    if (Number(declared) > maxBytes) throw new RequestBodyError("BODY_TOO_LARGE");
  }
  const reader = request.body?.getReader();
  if (!reader) throw new RequestBodyError("EMPTY_BODY");
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch { /* The size limit remains authoritative. */ }
        throw new RequestBodyError("BODY_TOO_LARGE");
      }
      chunks.push(part.value);
    }
  } finally {
    try { reader.releaseLock(); } catch { /* A cancelled stream may already be released. */ }
  }
  if (total === 0) throw new RequestBodyError("EMPTY_BODY");
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export async function readJsonObject(request: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/json(?:\s*;|\s*$)/i.test(contentType)) {
    throw new RequestBodyError("INVALID_CONTENT_TYPE");
  }
  const bytes = await readBoundedBody(request, maxBytes);
  let decoded: string;
  try { decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { throw new RequestBodyError("INVALID_UTF8"); }
  let value: unknown;
  try { value = JSON.parse(decoded); }
  catch { throw new RequestBodyError("INVALID_JSON"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RequestBodyError("INVALID_OBJECT");
  }
  return value as Record<string, unknown>;
}
