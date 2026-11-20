/**
 * Candidate-only transport guard for offline n8n rehearsal adapters.
 * No network is performed: every attempted request is rejected after recording
 * only non-sensitive destination metadata. Never wire this into production.
 */
export function createNoSendTransport({ allowedHosts = ["supabase.invalid", "edge.invalid"] } = {}) {
  const allow = new Set(allowedHosts.map((host) => String(host).toLowerCase()));
  const attempts = [];

  const fetchImpl = async (input, init = {}) => {
    const raw = input instanceof Request ? input.url : String(input);
    let url;
    try {
      url = new URL(raw);
    } catch {
      attempts.push({ destination: "<invalid-url>", method: String(init.method || "GET").toUpperCase() });
      throw new Error("no_send_transport_invalid_destination");
    }

    const host = url.hostname.toLowerCase();
    const method = String(init.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
    // Do not record query strings, headers, request bodies, or credentials.
    attempts.push({ destination: host, method });

    if (host === "api.mailersend.com" || host.endsWith(".mailersend.com")) {
      throw new Error("no_send_transport_provider_blocked");
    }
    if (url.protocol !== "https:" || !allow.has(host)) {
      throw new Error("no_send_transport_destination_blocked");
    }
    throw new Error("no_send_transport_mock_response_required");
  };

  return {
    fetchImpl,
    get attempts() { return attempts.map((item) => ({ ...item })); },
    get blockedProviderAttempts() {
      return attempts.filter((item) => item.destination === "api.mailersend.com" || item.destination.endsWith(".mailersend.com")).length;
    },
    get blockedUnapprovedAttempts() {
      return attempts.filter((item) => !allow.has(item.destination)).length;
    },
  };
}
