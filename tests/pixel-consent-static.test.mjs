import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const worker = readFileSync(new URL("../cloudflare/pixel-collector.js", import.meta.url), "utf8");
const migration = readFileSync(
  new URL("../supabase/migrations/202611210002_pixel_consent_and_marketing_gate.sql", import.meta.url),
  "utf8",
);
const pixel = readFileSync(
  new URL("../extensions/henvalt-pixel/src/index.js", import.meta.url),
  "utf8",
);

test("collector accepts cart removal and rejects analytics-denied events before Supabase", () => {
  assert.match(worker, /"product_removed_from_cart"/);
  assert.match(worker, /payload\.analytics_consent !== true/);
  assert.match(worker, /analytics_consent_required/);
  assert.ok(
    worker.indexOf("payload.analytics_consent !== true") < worker.indexOf("const digest = await sha256"),
    "consent rejection must happen before key hashing, rate limiting and Supabase",
  );
});

test("storefront extension itself suppresses collection without analytics consent", () => {
  assert.match(pixel, /privacy\?\.analyticsProcessingAllowed !== true/);
});

test("database ingestion rejects analytics-denied events before any writes", () => {
  assert.match(migration, /v_analytics_allowed := p_payload->>'analytics_consent' = 'true'/);
  assert.match(migration, /IF NOT v_analytics_allowed THEN[\s\S]*?accepted', false[\s\S]*?analytics_consent_required[\s\S]*?END IF;/);
  assert.ok(
    migration.indexOf("IF NOT v_analytics_allowed THEN") < migration.indexOf("INSERT INTO henvalt.pixel_rate_limits"),
    "database consent gate must precede rate-limit and canonical-event writes",
  );
});

test("browse recovery requires analytics, marketing privacy permission and email consent", () => {
  assert.match(migration, /e\.payload->>'analytics_consent' = 'true'/);
  assert.match(migration, /e\.metadata->>'marketing_allowed' = 'true'/);
  assert.match(migration, /c\.email_consent IS TRUE/);
});

test("database event allowlist includes product removal", () => {
  assert.match(migration, /'product_removed_from_cart'/);
});

test("Shopify Pixel and Cloudflare collector event allowlists stay identical", () => {
  const workerStart = worker.indexOf("const ALLOWED_EVENTS = new Set([");
  const workerEnd = worker.indexOf("]);", workerStart);
  const pixelStart = pixel.indexOf("const ALLOWED_EVENTS = [");
  const pixelEnd = pixel.indexOf("];", pixelStart);
  assert.ok(workerStart >= 0 && workerEnd > workerStart, "worker allowlist must be present");
  assert.ok(pixelStart >= 0 && pixelEnd > pixelStart, "pixel extension allowlist must be present");
  const workerBlock = worker.slice(workerStart, workerEnd);
  const pixelBlock = pixel.slice(pixelStart, pixelEnd);
  const values = (source) => [...source.matchAll(/"([^"]+)"/g)].map((match) => match[1]).sort();
  assert.deepEqual(values(workerBlock), values(pixelBlock));
});

test("browse delivery eligibility rechecks source-event consent at send time", () => {
  assert.ok(migration.includes("CREATE OR REPLACE FUNCTION henvalt.browse_opportunity_advanced("));
  assert.ok(migration.includes("e.metadata->>'analytics_processing_allowed' = 'true'"));
  assert.ok(migration.includes("e.metadata->>'marketing_allowed' = 'true'"));
  assert.ok(migration.includes("NOT COALESCE("));
});

test("browse candidate preserves ISO currency width and service-role RPC access", () => {
  assert.match(migration, /DROP FUNCTION IF EXISTS henvalt\.get_browse_abandonment_candidates\(integer, integer, integer\)/);
  assert.match(migration, /currency character\(3\)/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION henvalt\.get_browse_abandonment_candidates\(integer, integer, integer\) TO service_role/);
});

test("dashboard recovered activity uses confirmed order attribution, not opportunity value-at-risk", () => {
  const dashboardMigration = readFileSync(
    new URL("../supabase/migrations/202611210003_dashboard_confirmed_revenue_metrics.sql", import.meta.url),
    "utf8",
  );
  assert.match(dashboardMigration, /oa\.attribution_confidence = 'CONFIRMED'/);
  assert.match(dashboardMigration, /count\(DISTINCT oa\.order_id\)/);
  assert.match(dashboardMigration, /Awaiting confirmed attribution/);
  assert.match(dashboardMigration, /ri\.has_confirmed_attribution IS TRUE/);
});

test("dashboard revenue chart uses the confirmed revenue series", () => {
  const dashboard = readFileSync(new URL("../dashboard/index.html", import.meta.url), "utf8");
  assert.match(dashboard, /data\.revenueSeries\|\|\[\]/);
  assert.match(dashboard, /good&&x\.amount!=null\?money\(x\.amount,currency\):"—"/);
  assert.doesNotMatch(dashboard, /a\.filter\(x=>x\.outcome==="recovered"&&x\.amount!=null\)/);
});
