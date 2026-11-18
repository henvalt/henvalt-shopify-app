import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "henvalt-privacy-exports-v2";
const MAX_BYTES = 25 * 1024 * 1024;

const headers = {
  "cache-control": "no-store, max-age=0",
  "pragma": "no-cache",
  "x-content-type-options": "nosniff",
  "access-control-allow-origin": "null",
  "access-control-allow-headers": "authorization,content-type,apikey",
  "access-control-allow-methods": "POST,OPTIONS",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "content-type": "application/json" },
  });

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(SUPABASE_URL + path, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: "Bearer " + SERVICE_ROLE_KEY,
      ...(init.headers ?? {}),
    },
  });
}

async function recordEvidence(row: Record<string, unknown>): Promise<boolean> {
  const response = await rest("/rest/v1/shopify_privacy_delivery_evidence_v2", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "content-profile": "henvalt",
      prefer: "return=minimal",
    },
    body: JSON.stringify(row),
  });
  return response.ok;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json(503, { error: "privacy_download_not_configured" });
  }

  const auth = req.headers.get("authorization") ?? "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  if (!match) return json(401, { error: "authentication_required" });

  try {
    // Resolve identity through Supabase Auth; never trust user_metadata or client tenant IDs.
    const userResponse = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: { apikey: SERVICE_ROLE_KEY, authorization: "Bearer " + match[1] },
    });
    if (!userResponse.ok) return json(401, { error: "invalid_session" });
    const user = await userResponse.json();
    if (typeof user?.id !== "string") return json(401, { error: "invalid_session" });

    const body = await req.json().catch(() => null);
    const artifactId = typeof body?.artifact_id === "string" ? body.artifact_id : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(artifactId)) {
      return json(400, { error: "invalid_artifact_id" });
    }

    const membershipsResponse = await rest(
      "/rest/v1/tenant_memberships?select=tenant_id,role&user_id=eq." +
      encodeURIComponent(user.id) + "&role=in.(OWNER,ADMIN)",
      { headers: { "accept-profile": "henvalt" } },
    );
    if (!membershipsResponse.ok) return json(503, { error: "membership_check_unavailable" });
    const memberships = await membershipsResponse.json();
    if (!Array.isArray(memberships) || memberships.length === 0) {
      return json(403, { error: "owner_or_admin_required" });
    }

    const artifactResponse = await rest(
      "/rest/v1/shopify_privacy_export_artifacts_v2?select=*&id=eq." +
      encodeURIComponent(artifactId) + "&limit=1",
      { headers: { "accept-profile": "henvalt" } },
    );
    if (!artifactResponse.ok) return json(503, { error: "artifact_lookup_unavailable" });
    const artifacts = await artifactResponse.json();
    const artifact = Array.isArray(artifacts) ? artifacts[0] : null;
    if (!artifact) return json(404, { error: "artifact_not_found" });

    // The client supplies only the opaque artifact UUID. All tenant/store scope is derived here.
    const allowedTenant = memberships.some((m: any) =>
      m.tenant_id === artifact.tenant_id && (m.role === "OWNER" || m.role === "ADMIN")
    );
    if (!allowedTenant) return json(403, { error: "artifact_access_denied" });

    const tenantResponse = await rest(
      "/rest/v1/tenants?select=id,status&id=eq." + encodeURIComponent(artifact.tenant_id) + "&limit=1",
      { headers: { "accept-profile": "henvalt" } },
    );
    if (!tenantResponse.ok) return json(503, { error: "tenant_check_unavailable" });
    const tenants = await tenantResponse.json();
    if (!Array.isArray(tenants) || tenants[0]?.status !== "ACTIVE") {
      return json(403, { error: "tenant_inactive" });
    }

    const connectionResponse = await rest(
      "/rest/v1/shopify_connections?select=id,tenant_id,app_key,shop_domain,active&id=eq." +
      encodeURIComponent(artifact.connection_id) + "&limit=1",
      { headers: { "accept-profile": "henvalt" } },
    );
    if (!connectionResponse.ok) return json(503, { error: "connection_check_unavailable" });
    const connections = await connectionResponse.json();
    const connection = Array.isArray(connections) ? connections[0] : null;
    if (!connection || connection.active !== true ||
        connection.tenant_id !== artifact.tenant_id ||
        connection.app_key !== artifact.app_key ||
        connection.shop_domain !== artifact.shop_domain) {
      return json(403, { error: "store_binding_inactive" });
    }

    const receiptResponse = await rest(
      "/rest/v1/shopify_privacy_webhook_deliveries?select=id,tenant_id,connection_id,app_key,shop_domain&id=eq." +
      encodeURIComponent(artifact.receipt_id) + "&limit=1",
      { headers: { "accept-profile": "henvalt" } },
    );
    if (!receiptResponse.ok) return json(503, { error: "receipt_check_unavailable" });
    const receipts = await receiptResponse.json();
    const receipt = Array.isArray(receipts) ? receipts[0] : null;
    if (!receipt || receipt.id !== artifact.receipt_id ||
        receipt.tenant_id !== artifact.tenant_id ||
        receipt.connection_id !== artifact.connection_id ||
        receipt.app_key !== artifact.app_key ||
        receipt.shop_domain !== artifact.shop_domain) {
      return json(403, { error: "receipt_binding_invalid" });
    }

    const expiresAt = Date.parse(artifact.expires_at);
    if (artifact.state !== "AVAILABLE" ||
        artifact.completeness_status !== "COMPLETE_FOR_MERCHANT_REVIEW" ||
        !Number.isFinite(expiresAt) || expiresAt <= Date.now() ||
        artifact.bucket_id !== BUCKET ||
        typeof artifact.object_key !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.json$/i.test(artifact.object_key) ||
        !Number.isInteger(artifact.byte_count) || artifact.byte_count < 1 ||
        artifact.byte_count > MAX_BYTES ||
        !/^[0-9a-f]{64}$/.test(artifact.sha256_hex)) {
      return json(409, { error: "artifact_not_available" });
    }

    const correlationId = crypto.randomUUID();
    const evidenceBase = {
      receipt_id: artifact.receipt_id,
      tenant_id: artifact.tenant_id,
      connection_id: artifact.connection_id,
      app_key: artifact.app_key,
      shop_domain: artifact.shop_domain,
      artifact_id: artifact.id,
      actor_user_id: user.id,
      correlation_id: correlationId,
    };

    if (!await recordEvidence({
      ...evidenceBase,
      event_type: "DOWNLOAD_AUTHORIZED",
      outcome_code: "OWNER_ADMIN_AUTHORIZED",
    })) return json(503, { error: "audit_write_unavailable" });

    // Server-side fetch from the private bucket. No signed URL or object key leaves this function.
    const objectResponse = await rest(
      "/storage/v1/object/" + BUCKET + "/" + encodeURIComponent(artifact.object_key),
    );
    if (!objectResponse.ok) {
      await recordEvidence({
        ...evidenceBase,
        event_type: "DOWNLOAD_STREAM_FAILED",
        outcome_code: "PRIVATE_OBJECT_FETCH_FAILED",
      });
      return json(503, { error: "artifact_stream_unavailable" });
    }

    const bytes = new Uint8Array(await objectResponse.arrayBuffer());
    const digest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
    if (bytes.byteLength !== artifact.byte_count || digest !== artifact.sha256_hex) {
      await recordEvidence({
        ...evidenceBase,
        event_type: "DOWNLOAD_STREAM_FAILED",
        outcome_code: "OBJECT_INTEGRITY_MISMATCH",
      });
      return json(503, { error: "artifact_integrity_check_failed" });
    }

    if (!await recordEvidence({
      ...evidenceBase,
      event_type: "DOWNLOAD_STREAM_STARTED",
      outcome_code: "INTEGRITY_VERIFIED_RESPONSE_READY",
    })) return json(503, { error: "audit_write_unavailable" });

    return new Response(bytes, {
      status: 200,
      headers: {
        ...headers,
        "content-type": "application/json",
        "content-length": String(bytes.byteLength),
        "content-disposition": 'attachment; filename="henvalt-shopify-privacy-export.json"',
      },
    });
  } catch {
    return json(500, { error: "privacy_download_failed" });
  }
});
