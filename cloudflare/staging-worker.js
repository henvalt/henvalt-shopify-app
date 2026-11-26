import { handleRequest } from "./worker.js";

const PRODUCTION_N8N_HOSTS = new Set([
  "n8n.henvalt.com",
  "henvalt26.app.n8n.cloud",
]);
const EXPECTED_INGEST_PATH = "/webhook/henvalt/ingest-candidate-no-send";

function stagingUpstream(env) {
  try {
    const url = new URL(env.N8N_INGEST_URL);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return null;
    const expectedHost = String(env.HENVALT_STAGE_N8N_HOST ?? "").trim().toLowerCase();
    if (!expectedHost || url.hostname.toLowerCase() !== expectedHost) return null;
    if (PRODUCTION_N8N_HOSTS.has(url.hostname.toLowerCase())) return null;
    if (url.pathname !== EXPECTED_INGEST_PATH) return null;
    if (url.hostname.endsWith(".invalid")) return null;
    return url;
  } catch {
    return null;
  }
}

export async function handleStagingRequest(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  const noSendEnabled = env.HENVALT_STAGE_NO_SEND === "true";
  const stubMode = env.HENVALT_STAGE_PROVIDER_MODE === "stub";
  const upstream = stagingUpstream(env);
  const configured = noSendEnabled && stubMode &&
    typeof env.SHOPIFY_API_SECRET === "string" && env.SHOPIFY_API_SECRET.length > 0 &&
    upstream !== null;

  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    return Response.json({
      service: "henvalt-shopify-ingress-staging-no-send",
      configured,
      no_send: noSendEnabled,
      provider_mode: stubMode ? "stub" : "blocked",
    }, { headers: { "cache-control": "no-store" } });
  }

  if (!noSendEnabled || !stubMode || !upstream) {
    return Response.json({ error: "staging_no_send_guard_closed" }, { status: 503 });
  }

  return handleRequest(request, env, fetchImpl);
}

export default {
  fetch(request, env) {
    return handleStagingRequest(request, env);
  },
};
