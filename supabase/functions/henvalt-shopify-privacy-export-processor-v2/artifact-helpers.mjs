export function canonicalJson(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonicalJson).join(",") + "]";
  const keys = Object.keys(value).sort();
  return "{" + keys.map((key) => JSON.stringify(key) + ":" + canonicalJson(value[key])).join(",") + "}";
}
export function buildManifestSummary(records) {
  if (!records || typeof records !== "object" || Array.isArray(records)) throw new TypeError("records must be an object");
  const categories = Object.keys(records).sort().map((name) => {
    if (!/^[a-z][a-z0-9_]{0,63}$/.test(name)) throw new TypeError("invalid export category");
    const value = records[name];
    const count = Array.isArray(value) ? value.length : value === null ? 0 : typeof value === "object" ? 1 : NaN;
    if (!Number.isSafeInteger(count) || count < 0) throw new TypeError("unsupported export category shape");
    return { name, count };
  });
  if (categories.length > 64) throw new RangeError("too many export categories");
  return { schema_version: 1, categories };
}
export function isCompleteExport(draft, claim) {
  return Boolean(draft && draft.exported === true && draft.completion_eligible === true &&
    draft.legacy_scope_review_required === false && draft.customer_identity_found === true &&
    draft.shop_domain === claim.shop_domain && draft.shopify_customer_id === claim.customer_id &&
    draft.records && typeof draft.records === "object" && !Array.isArray(draft.records) &&
    (draft.review_code === null || draft.review_code === undefined));
}
export function makeOpaqueObjectKey(uuid) {
  if (typeof uuid !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(uuid)) {
    throw new TypeError("cryptographic UUID required");
  }
  return uuid.toLowerCase() + ".json";
}
export function serializeArtifact(draft) {
  const bytes = new TextEncoder().encode(canonicalJson(draft));
  if (bytes.byteLength < 1 || bytes.byteLength > 25 * 1024 * 1024) throw new RangeError("privacy export artifact exceeds size limit");
  return bytes;
}
