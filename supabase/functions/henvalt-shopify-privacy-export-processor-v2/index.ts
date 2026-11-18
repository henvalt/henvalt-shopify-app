import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { buildManifestSummary, isCompleteExport, makeOpaqueObjectKey, serializeArtifact } from "./artifact-helpers.mjs";

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "henvalt-privacy-exports-v2";
const MAX_BYTES = 25 * 1024 * 1024;
type Claim = { receipt_id: string; claim_token: string; app_key: string; tenant_id: string; connection_id: string; shop_domain: string; topic: string; customer_id: string; request_id: string; body_sha256: string; attempt_count: number; lease_expires_at: string };

const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" },
});
async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(SUPABASE_URL + path, { ...init, headers: {
    apikey: SERVICE_ROLE_KEY, authorization: "Bearer " + SERVICE_ROLE_KEY, ...(init.headers ?? {}),
  }});
}
async function rpc(name: string, body: Record<string, unknown>): Promise<Response> {
  return rest("/rest/v1/rpc/" + name, { method: "POST", headers: {
    "content-type": "application/json", "accept-profile": "henvalt", "content-profile": "henvalt",
  }, body: JSON.stringify(body) });
}
async function patchArtifact(id: string, state: "AVAILABLE" | "PURGE_PENDING"): Promise<boolean> {
  const response = await rest("/rest/v1/shopify_privacy_export_artifacts_v2?id=eq." +
    encodeURIComponent(id) + "&state=eq.STAGED", {
    method: "PATCH", headers: { "content-type": "application/json", "accept-profile": "henvalt",
      "content-profile": "henvalt", prefer: "return=representation" }, body: JSON.stringify({ state }),
  });
  if (!response.ok) return false;
  const rows = await response.json().catch(() => []);
  return Array.isArray(rows) && rows.length === 1 && rows[0].id === id && rows[0].state === state;
}
async function recordGeneratedEvidence(claim: Claim, artifactId: string, correlationId: string): Promise<Response> {
  return rest("/rest/v1/shopify_privacy_delivery_evidence_v2", { method: "POST", headers: {
    "content-type": "application/json", "content-profile": "henvalt", prefer: "return=minimal",
  }, body: JSON.stringify({
    receipt_id: claim.receipt_id, tenant_id: claim.tenant_id, connection_id: claim.connection_id,
    app_key: claim.app_key, shop_domain: claim.shop_domain, artifact_id: artifactId,
    event_type: "ARTIFACT_GENERATED", outcome_code: "PRIVATE_OBJECT_INTEGRITY_VERIFIED",
    correlation_id: correlationId,
  })});
}
async function holdForReview(claim: Claim): Promise<boolean> {
  // The existing completion RPC is fail-closed: it clears the lease and leaves the request REVIEW_REQUIRED.
  const response = await rpc("complete_shopify_privacy_request_v2", {
    p_receipt_id: claim.receipt_id, p_claim_token: claim.claim_token, p_processor_confirmed: true,
  });
  if (!response.ok) return false;
  return await response.json().catch(() => null) === false;
}
async function retryClaim(claim: Claim, code: string): Promise<boolean> {
  const response = await rpc("fail_shopify_privacy_request_v2", {
    p_receipt_id: claim.receipt_id, p_claim_token: claim.claim_token,
    p_failure_code: code, p_retryable: true,
  });
  return response.ok && await response.json().catch(() => false) === true;
}
function artifactTtlSeconds(): number {
  const raw = Deno.env.get("HENVALT_PRIVACY_ARTIFACT_TTL_SECONDS") ?? "";
  if (!/^[0-9]{1,7}$/.test(raw)) throw new Error("artifact_retention_not_configured");
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 3600 || value > 604800) throw new Error("artifact_retention_out_of_bounds");
  return value;
}
async function processOne(): Promise<Response> {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json(503, { error: "processor_not_configured" });
  const claimResponse = await rpc("claim_shopify_privacy_request_v2", { p_lease_seconds: 300 });
  if (!claimResponse.ok) return json(503, { error: "privacy_claim_unavailable" });
  const claimRows = await claimResponse.json().catch(() => null);
  const claim = Array.isArray(claimRows) ? claimRows[0] as Claim | undefined : undefined;
  if (!claim) return json(200, { status: "no_work" });
  if (claim.topic !== "customers/data_request" || !claim.receipt_id || !claim.claim_token ||
      !claim.customer_id || !claim.tenant_id || !claim.connection_id || !claim.app_key || !claim.shop_domain) {
    const released = await retryClaim(claim, "UNSUPPORTED_OR_INVALID_PRIVACY_CLAIM");
    return released ? json(202, { status: "claim_released" }) : json(503, { error: "claim_release_failed" });
  }
  try {
    const draftResponse = await rpc("build_shopify_customer_privacy_export_v2", {
      p_receipt_id: claim.receipt_id, p_claim_token: claim.claim_token,
    });
    if (!draftResponse.ok) {
      const released = await retryClaim(claim, "EXPORT_DRAFT_UNAVAILABLE");
      return released ? json(202, { status: "retry_scheduled" }) : json(503, { error: "claim_release_failed" });
    }
    const draft = await draftResponse.json();
    if (!isCompleteExport(draft, claim)) {
      const held = await holdForReview(claim);
      return held ? json(202, { status: "review_required", code: "EXPORT_SCOPE_REQUIRES_REVIEW" })
        : json(503, { error: "review_hold_failed" });
    }
    // The current SQL builder intentionally fails this gate until legacy-scope review is resolved.
    const bytes = serializeArtifact(draft);
    if (bytes.byteLength > MAX_BYTES) {
      const released = await retryClaim(claim, "EXPORT_ARTIFACT_TOO_LARGE");
      return released ? json(202, { status: "retry_scheduled" }) : json(503, { error: "claim_release_failed" });
    }
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const sha256Hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    const generationId = crypto.randomUUID();
    const objectKey = makeOpaqueObjectKey(crypto.randomUUID());
    const correlationId = crypto.randomUUID();
    const expiresAt = new Date(Date.now() + artifactTtlSeconds() * 1000).toISOString();

    // Manifest metadata contains category names and counts only, never export values or identifiers.
    const manifestSummary = buildManifestSummary(draft.records);
    const insertResponse = await rest("/rest/v1/shopify_privacy_export_artifacts_v2", {
      method: "POST", headers: { "content-type": "application/json", "content-profile": "henvalt",
        prefer: "return=representation" },
      body: JSON.stringify({
        receipt_id: claim.receipt_id, tenant_id: claim.tenant_id, connection_id: claim.connection_id,
        app_key: claim.app_key, shop_domain: claim.shop_domain, generation_id: generationId,
        object_key: objectKey, sha256_hex: sha256Hex, byte_count: bytes.byteLength,
        completeness_status: "COMPLETE_FOR_MERCHANT_REVIEW", manifest_schema_version: 1,
        manifest_summary: manifestSummary, state: "STAGED", expires_at: expiresAt,
      }),
    });
    if (!insertResponse.ok) {
      const released = await retryClaim(claim, "ARTIFACT_METADATA_WRITE_FAILED");
      return released ? json(202, { status: "retry_scheduled" }) : json(503, { error: "claim_release_failed" });
    }
    const inserted = await insertResponse.json().catch(() => []);
    const artifact = Array.isArray(inserted) ? inserted[0] : null;
    if (!artifact?.id) return json(503, { error: "artifact_metadata_unconfirmed" });

    const uploadResponse = await rest("/storage/v1/object/" + BUCKET + "/" + encodeURIComponent(objectKey), {
      method: "POST", headers: { "content-type": "application/json", "cache-control": "no-store", "x-upsert": "false" },
      body: bytes,
    });
    if (!uploadResponse.ok) {
      await patchArtifact(artifact.id, "PURGE_PENDING");
      return json(503, { error: "private_object_upload_unconfirmed" });
    }
    const verifyResponse = await rest("/storage/v1/object/" + BUCKET + "/" + encodeURIComponent(objectKey));
    if (!verifyResponse.ok) {
      await patchArtifact(artifact.id, "PURGE_PENDING");
      return json(503, { error: "private_object_readback_failed" });
    }
    const verifiedBytes = new Uint8Array(await verifyResponse.arrayBuffer());
    const verifiedDigest = await crypto.subtle.digest("SHA-256", verifiedBytes);
    const verifiedHex = Array.from(new Uint8Array(verifiedDigest), (b) => b.toString(16).padStart(2, "0")).join("");
    if (verifiedBytes.byteLength !== bytes.byteLength || verifiedHex !== sha256Hex) {
      await patchArtifact(artifact.id, "PURGE_PENDING");
      return json(503, { error: "private_object_integrity_mismatch" });
    }
    const evidenceResponse = await recordGeneratedEvidence(claim, artifact.id, correlationId);
    if (!evidenceResponse.ok) {
      await patchArtifact(artifact.id, "PURGE_PENDING");
      return json(503, { error: "artifact_evidence_write_failed" });
    }
    if (!await patchArtifact(artifact.id, "AVAILABLE")) {
      await patchArtifact(artifact.id, "PURGE_PENDING");
      return json(503, { error: "artifact_activation_unconfirmed" });
    }
    // Availability for merchant review is not proof of delivery to the data subject.
    return json(201, { status: "artifact_available_for_merchant_review", artifact_id: artifact.id });
  } catch {
    const released = await retryClaim(claim, "PRIVACY_ARTIFACT_PROCESSOR_FAILED");
    return released ? json(202, { status: "retry_scheduled" }) : json(503, { error: "privacy_processor_failed" });
  }
}
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const authorization = req.headers.get("authorization") ?? "";
  if (!SERVICE_ROLE_KEY || authorization !== "Bearer " + SERVICE_ROLE_KEY) {
    return json(401, { error: "service_authentication_required" });
  }
  return await processOne();
});
