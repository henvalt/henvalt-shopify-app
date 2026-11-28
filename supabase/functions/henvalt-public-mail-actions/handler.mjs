const STAGING_SUPABASE_URL = "https://xidhtmrfvsgfmyltjuja.supabase.co";
const TOKEN_PATTERN = /^[0-9a-f]{48}$/;
const SECURITY_HEADERS = {
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; form-action 'self'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
};

function html(status, body) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", ...SECURITY_HEADERS },
  });
}

function text(status, body) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...SECURITY_HEADERS },
  });
}

function page(title, message, action, button) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>' + title + '</title><style>body{margin:0;background:#f5f5f2;color:#171717;font:16px/1.6 Arial,sans-serif;display:grid;min-height:100vh;place-items:center}.card{box-sizing:border-box;width:min(92vw,480px);padding:36px;background:#fff;border:1px solid #e7e7e2;border-radius:16px}h1{font-size:24px;line-height:1.2}p{color:#555}button{background:#171717;color:#fff;border:0;border-radius:8px;padding:13px 20px;font-weight:700;cursor:pointer}</style></head><body><main class="card"><h1>' +
    title + '</h1><p>' + message + '</p><form method="post" action="' + action + '"><button type="submit">' + button + '</button></form></main></body></html>';
}

export function createPublicMailActionsHandler({ supabaseUrl, serviceRoleKey, fetchImpl = fetch }) {
  const configured = supabaseUrl === STAGING_SUPABASE_URL && !!serviceRoleKey;

  async function rpc(name, args) {
    const response = await fetchImpl(supabaseUrl + "/rest/v1/rpc/" + name, {
      method: "POST",
      redirect: "error",
      headers: {
        apikey: serviceRoleKey,
        authorization: "Bearer " + serviceRoleKey,
        "content-type": "application/json",
        accept: "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify(args),
    });
    if (!response.ok) throw new Error("public_action_rpc_failed");
    return response.json();
  }

  return async (request) => {
    if (!configured) return text(503, "Service temporarily unavailable.");
    if (!["GET", "POST"].includes(request.method)) {
      return text(405, "Method not allowed.");
    }

    let segments;
    try {
      const url = new URL(request.url);
      segments = url.pathname.split("/").filter(Boolean);
    } catch {
      return text(400, "Invalid request.");
    }
    const action = segments.at(-2);
    const token = segments.at(-1);
    if (!["track", "unsubscribe"].includes(action) || !TOKEN_PATTERN.test(token || "")) {
      return text(404, "This link is invalid or has expired.");
    }

    try {
      if (action === "track") {
        if (request.method === "GET") {
          const destination = await rpc("preview_tracking_destination", { p_token: token });
          if (typeof destination !== "string" || !destination) {
            return text(404, "This link is invalid or has expired.");
          }
          let parsed;
          try { parsed = new URL(destination); } catch { return text(404, "This link is invalid or has expired."); }
          if (parsed.protocol !== "https:" || parsed.username || parsed.password) {
            return text(404, "This link is invalid or has expired.");
          }
          return html(200, page(
            "Continue to the store",
            "Your secure store link is ready. Continue when you are ready.",
            request.url,
            "Continue",
          ));
        }

        const destination = await rpc("confirm_tracking_click", { p_token: token });
        if (typeof destination !== "string" || !destination) {
          return text(404, "This link is invalid or has expired.");
        }
        let parsed;
        try { parsed = new URL(destination); } catch { return text(404, "This link is invalid or has expired."); }
        if (parsed.protocol !== "https:" || parsed.username || parsed.password) {
          return text(404, "This link is invalid or has expired.");
        }
        return new Response(null, {
          status: 303,
          headers: { location: parsed.toString(), ...SECURITY_HEADERS },
        });
      }

      if (request.method === "GET") {
        const valid = await rpc("validate_unsubscribe_token", { p_token: token });
        if (valid !== true) return text(404, "This link is invalid or has expired.");
        return html(200, page(
          "Unsubscribe from recovery emails",
          "If you no longer want recovery emails from this store, confirm below. This will not affect essential order updates.",
          request.url,
          "Confirm unsubscribe",
        ));
      }

      const unsubscribed = await rpc("unsubscribe_customer_by_token", { p_token: token });
      if (unsubscribed !== true) return text(404, "This link is invalid or has expired.");
      return html(200,
        '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Unsubscribed</title></head>' +
        '<body style="margin:0;padding:48px 16px;background:#f5f5f2;color:#171717;font:16px/1.6 Arial,sans-serif"><main style="max-width:480px;margin:0 auto;padding:32px;background:#fff;border:1px solid #e7e7e2;border-radius:16px"><h1>You are unsubscribed</h1><p>You will no longer receive recovery emails from this store.</p></main></body></html>');
    } catch {
      return text(503, "We could not complete this request right now. Please try again.");
    }
  };
}

export { STAGING_SUPABASE_URL, TOKEN_PATTERN };
