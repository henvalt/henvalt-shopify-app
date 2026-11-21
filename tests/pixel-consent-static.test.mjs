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
