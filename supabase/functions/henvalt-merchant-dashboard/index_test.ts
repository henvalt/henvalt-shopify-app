import { createDashboardHandler } from "./index.ts";

const OPTIONS = {
  supabaseUrl: "https://project.example",
  serviceRoleKey: "service-role-test-only",
  anonKey: "anon-test-only",
  now: () => new Date("2026-11-23T12:00:00.000Z"),
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

function request(path = "", token: string | null = "valid-test-token", method = "GET"): Request {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", "Bearer " + token);
  return new Request("https://dashboard.example" + path, { method, headers });
}

function queuedFetch(responses: Response[]) {
  const calls: Array<{ input: string; init?: RequestInit }> = [];
  const fetchImpl = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    calls.push({ input: String(input), init });
    const response = responses.shift();
    if (!response) throw new Error("Unexpected fetch call: " + String(input));
    return response;
  };
  return { fetchImpl, calls, remaining: () => responses.length };
}

Deno.test("rejects missing bearer token before contacting Auth", async () => {
  const mock = queuedFetch([]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request("", null));
  if (response.status !== 401 || mock.calls.length !== 0) throw new Error("missing token was not rejected early");
});

Deno.test("rejects invalid Auth session and never performs privileged lookups", async () => {
  const mock = queuedFetch([json({ message: "invalid token" }, 401)]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request());
  if (response.status !== 401 || (await response.json()).error !== "invalid_session") throw new Error("invalid token accepted");
  if (mock.calls.length !== 1 || !mock.calls[0].input.endsWith("/auth/v1/user")) throw new Error("privileged lookup occurred");
  if (new Headers(mock.calls[0].init?.headers).get("apikey") !== OPTIONS.anonKey) throw new Error("Auth must use anon key");
  if (new Headers(mock.calls[0].init?.headers).get("authorization") !== "Bearer valid-test-token") throw new Error("Bearer token was not normalized before Auth validation");
});

Deno.test("rejects zero tenant memberships", async () => {
  const mock = queuedFetch([json({ id: "user-1" }), json([])]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request());
  if (response.status !== 403 || (await response.json()).error !== "one_active_tenant_membership_required") {
    throw new Error("zero memberships not rejected");
  }
  if (mock.calls.length !== 2) throw new Error("unexpected calls after zero membership");
});

Deno.test("rejects multiple tenant memberships to prevent ambiguous tenant selection", async () => {
  const mock = queuedFetch([json({ id: "user-1" }), json([{ tenant_id: "tenant-a" }, { tenant_id: "tenant-b" }])]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request());
  if (response.status !== 403 || mock.calls.length !== 2) throw new Error("multiple memberships not rejected");
});

Deno.test("privileged membership lookup is scoped to Auth user and uses server credential", async () => {
  const mock = queuedFetch([json({ id: "user / one" }), json([])]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  await handler(request());
  const call = mock.calls[1];
  if (!call.input.includes("user_id=eq.user%20%2F%20one")) throw new Error("user id not safely encoded in membership filter");
  const headers = new Headers(call.init?.headers);
  if (headers.get("apikey") !== OPTIONS.serviceRoleKey ||
      headers.get("authorization") !== "Bearer " + OPTIONS.serviceRoleKey ||
      headers.get("accept-profile") !== "henvalt") throw new Error("membership lookup not using expected private schema credentials");
});

Deno.test("rejects zero active Shopify connections", async () => {
  const mock = queuedFetch([json({ id: "user-1" }), json([{ tenant_id: "tenant-a" }]), json([])]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request());
  if (response.status !== 409 || (await response.json()).error !== "active_shop_connection_required") {
    throw new Error("zero active shops not rejected");
  }
});

Deno.test("rejects multiple active Shopify connections", async () => {
  const mock = queuedFetch([
    json({ id: "user-1" }),
    json([{ tenant_id: "tenant-a" }]),
    json([{ shop_domain: "one.myshopify.com" }, { shop_domain: "two.myshopify.com" }]),
  ]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request());
  if (response.status !== 409 || mock.calls.length !== 3) throw new Error("multiple shops not rejected");
});

Deno.test("rejects invalid range before summary and ledger queries", async () => {
  const mock = queuedFetch([
    json({ id: "user-1" }),
    json([{ tenant_id: "tenant-a" }]),
    json([{ shop_domain: "one.myshopify.com" }]),
  ]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request("?from=2026-02-31"));
  if (response.status !== 400 || mock.calls.length !== 3) throw new Error("invalid range reached downstream queries");
});

Deno.test("returns tenant-scoped confirmed ledger and revenue series for one authenticated shop", async () => {
  const mock = queuedFetch([
    json({ id: "user-1" }),
    json([{ tenant_id: "tenant-a" }]),
    json([{ shop_domain: "one.myshopify.com" }]),
    json({ linked: true, currency: "USD", metrics: { revenueRecovered: 42 }, activity: [
      { id: "opportunity-1", outcome: "recovered", amount: 999, currency: "USD" },
      { id: "opportunity-2", outcome: "recovered", amount: 500, currency: "USD" },
      { id: "opportunity-3", outcome: "pending", amount: null },
    ] }),
    json({ series: [{ bucket: "2026-11-23T00:00:00.000Z", recovered_revenue: 42 }], current_revenue: 42, previous_revenue: 20, change_percent: 110 }),
    json([{ id: "ledger-1", opportunity_id: "opportunity-1", amount: 42, currency: "USD", billable: true, attribution_confidence: "CONFIRMED" }]),
  ]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request("?from=2026-11-01&to=2026-11-23&granularity=week"));
  const body = await response.json();
  if (response.status !== 200 || body.ledger.length !== 1 || body.revenueSeries.length !== 1) {
    throw new Error("valid dashboard response missing expected data");
  }
  if (body.revenueSeries[0].recovered_revenue !== 42) throw new Error("revenue series bucket shape differs from the live RPC contract");
  if (body.activity[0].amount !== 42) throw new Error("activity must use the confirmed ledger amount, not opportunity value at risk");
  if (body.activity[1].amount !== null) throw new Error("unmatched recovered activity must not display unverified revenue");
  if (body.activity[2].amount !== null) throw new Error("pending activity must not display a revenue amount");
  if (body.range.from !== "2026-11-01" || body.range.granularity !== "week") throw new Error("range not preserved");
  const connectionUrl = mock.calls[2].input;
  if (!connectionUrl.includes("tenant_id=eq.tenant-a") || !connectionUrl.includes("tenants.status=eq.ACTIVE")) {
    throw new Error("shop connection lookup not tenant/status scoped");
  }
  const rpcBody = JSON.parse(String(mock.calls[3].init?.body));
  if (rpcBody.p_shop_domain !== "one.myshopify.com") throw new Error("summary RPC not scoped to connected shop");
  const seriesBody = JSON.parse(String(mock.calls[4].init?.body));
  if (seriesBody.p_granularity !== "week") throw new Error("granularity not passed to revenue RPC");
  const ledgerUrl = new URL(mock.calls[5].input);
  if (ledgerUrl.searchParams.get("tenant_id") !== "eq.tenant-a" ||
      ledgerUrl.searchParams.get("entry_type") !== "eq.RECOVERY" ||
      ledgerUrl.searchParams.get("attribution_confidence") !== "eq.CONFIRMED" ||
      ledgerUrl.searchParams.get("billable") !== "eq.true" ||
      !ledgerUrl.searchParams.get("select")?.includes("opportunity_id")) {
    throw new Error("ledger query missing tenant/recovery/confirmed filters");
  }
  for (const call of mock.calls.slice(1)) {
    const headers = new Headers(call.init?.headers);
    if (headers.get("apikey") !== OPTIONS.serviceRoleKey) throw new Error("privileged query missing server-only key");
  }
});

Deno.test("fails closed when required environment configuration is missing", async () => {
  const handler = createDashboardHandler({ ...OPTIONS, serviceRoleKey: "", fetchImpl: async () => {
    throw new Error("fetch must not be called");
  } });
  const response = await handler(request());
  if (response.status !== 503 || (await response.json()).error !== "dashboard_not_configured") {
    throw new Error("missing configuration did not fail closed");
  }
});

Deno.test("handles preflight and rejects unsupported methods", async () => {
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: async () => {
    throw new Error("fetch must not be called");
  } });
  const preflight = await handler(request("", null, "OPTIONS"));
  const method = await handler(request("", null, "POST"));
  if (preflight.status !== 204 || method.status !== 405) throw new Error("method contract mismatch");
});


Deno.test("does not collapse mixed-currency ledger rows into a false dashboard total", async () => {
  const mock = queuedFetch([
    json({ id: "user-1" }),
    json([{ tenant_id: "tenant-a" }]),
    json([{ shop_domain: "one.myshopify.com" }]),
    json({
      linked: true,
      currency: "USD",
      revenueCurrencyConflict: true,
      revenueByCurrency: [{ currency: "GBP", amount: 50 }, { currency: "USD", amount: 100 }],
      metrics: { revenueRecovered: null, currency: "USD", recoveredOrders: 2 },
      activity: [
        { id: "opportunity-mixed", outcome: "recovered", amount: null },
        { id: "opportunity-gbp", outcome: "recovered", amount: null },
      ],
      byEvent: [],
    }),
    json({
      series: [],
      current_revenue: null,
      previous_revenue: null,
      change_percent: null,
      current_currency_conflict: true,
      comparison_currency_conflict: true,
    }),
    json([
      { id: "ledger-usd", opportunity_id: "opportunity-mixed", amount: 100, currency: "USD" },
      { id: "ledger-gbp", opportunity_id: "opportunity-mixed", amount: 50, currency: "GBP" },
      { id: "ledger-gbp-only", opportunity_id: "opportunity-gbp", amount: 20, currency: "GBP" },
    ]),
  ]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request("?from=2026-11-01&to=2026-11-23"));
  const body = await response.json();
  if (response.status !== 200) throw new Error("mixed-currency dashboard response failed");
  if (body.revenueCurrencyConflict !== true || body.revenueByCurrency.length !== 2) {
    throw new Error("currency conflict and per-currency totals were not preserved");
  }
  if (body.metrics.revenueRecovered !== null || body.revenueComparison.currentRevenue !== null) {
    throw new Error("mixed-currency total was converted into a misleading numeric value");
  }
  if (body.revenueSeries.length !== 0) throw new Error("mixed-currency trend should not be summed");
  if (body.activity[0].amount !== null || body.activity[0].amountCurrencyConflict !== true) {
    throw new Error("opportunity-level mixed currencies were incorrectly summed");
  }
  if (body.activity[1].amount !== 20 || body.activity[1].currency !== "GBP") {
    throw new Error("single-currency opportunity amount was not preserved");
  }
});

Deno.test("aggregates multiple confirmed ledger rows for one opportunity only when currency matches", async () => {
  const mock = queuedFetch([
    json({ id: "user-1" }),
    json([{ tenant_id: "tenant-a" }]),
    json([{ shop_domain: "one.myshopify.com" }]),
    json({
      linked: true,
      currency: "USD",
      revenueCurrencyConflict: false,
      revenueByCurrency: [{ currency: "USD", amount: 42 }],
      metrics: { revenueRecovered: 42, currency: "USD", recoveredOrders: 2 },
      activity: [{ id: "opportunity-1", outcome: "recovered", amount: null }],
    }),
    json({
      series: [{ bucket: "2026-11-23T00:00:00.000Z", recovered_revenue: 42 }],
      current_revenue: 42,
      previous_revenue: 0,
      change_percent: null,
      current_currency_conflict: false,
      comparison_currency_conflict: false,
    }),
    json([
      { id: "ledger-1", opportunity_id: "opportunity-1", amount: 12, currency: "USD" },
      { id: "ledger-2", opportunity_id: "opportunity-1", amount: 30, currency: "USD" },
    ]),
  ]);
  const handler = createDashboardHandler({ ...OPTIONS, fetchImpl: mock.fetchImpl });
  const response = await handler(request("?from=2026-11-01&to=2026-11-23"));
  const body = await response.json();
  if (response.status !== 200 || body.activity[0].amount !== 42 || body.activity[0].currency !== "USD") {
    throw new Error("same-currency confirmed ledger rows were not summed per opportunity");
  }
  if (body.revenueCurrencyConflict !== false || body.revenueComparison.currentRevenue !== 42) {
    throw new Error("single-currency revenue was not preserved");
  }
});
