/**
 * Candidate-only transport guard for offline n8n rehearsal adapters.
 * No network is performed: every attempted request is rejected after recording
 * only non-sensitive destination metadata. Never wire this into production.
 */
const normalizeHost = (host) => String(host).toLowerCase().replace(/\.+$/, "");
const isMailerSendHost = (host) =>
  host === "mailersend.com" || host.endsWith(".mailersend.com");

export function createNoSendTransport({ allowedHosts = ["supabase.invalid", "edge.invalid"] } = {}) {
  const allow = new Set(allowedHosts.map(normalizeHost));
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

    // DNS treats a terminal dot as the absolute form of the same hostname.
    const host = normalizeHost(url.hostname);
    const method = String(init.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
    // Do not record query strings, headers, request bodies, or credentials.
    attempts.push({ destination: host, method });

    if (isMailerSendHost(host)) {
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
      return attempts.filter((item) => isMailerSendHost(item.destination)).length;
    },
    get blockedUnapprovedAttempts() {
      return attempts.filter((item) => !allow.has(item.destination)).length;
    },
  };
}
