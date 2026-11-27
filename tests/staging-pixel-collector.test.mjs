import test from "node:test";
import assert from "node:assert/strict";
import { stagingPixelCollectorConfigured, default as worker } from "../cloudflare/staging-pixel-collector.js";

const valid = {
  HENVALT_STAGE_NO_SEND: "true",
  SUPABASE_URL: "https://xidhtmrfvsgfmyltjuja.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_staging_placeholder",
  COLLECTOR_SHARED_SECRET: "s".repeat(40),
  RATE_LIMITER: { limit: async () => ({ success: true }) },
};

test("staging pixel collector accepts only the exact isolated staging Supabase identity", () => {
  assert.equal(stagingPixelCollectorConfigured(valid), true);
});

test("staging pixel collector rejects production or arbitrary Supabase hosts", () => {
  for (const SUPABASE_URL of [
    "https://ocyplckdojdubyrsxcxa.supabase.co",
    "https://attacker.example",
    "http://xidhtmrfvsgfmyltjuja.supabase.co",
    "https://xidhtmrfvsgfmyltjuja.supabase.co.evil.example",
  ]) {
    assert.equal(stagingPixelCollectorConfigured({ ...valid, SUPABASE_URL }), false, SUPABASE_URL);
  }
});

test("staging pixel collector requires no-send, publishable key, shared secret and rate limiter", () => {
  assert.equal(stagingPixelCollectorConfigured({ ...valid, HENVALT_STAGE_NO_SEND: "false" }), false);
  assert.equal(stagingPixelCollectorConfigured({ ...valid, SUPABASE_PUBLISHABLE_KEY: "service_role_secret" }), false);
  assert.equal(stagingPixelCollectorConfigured({ ...valid, COLLECTOR_SHARED_SECRET: "short" }), false);
  assert.equal(stagingPixelCollectorConfigured({ ...valid, RATE_LIMITER: undefined }), false);
});

test("staging health is explicit and reports blocked configuration without contacting Supabase", async () => {
  const response = await worker.fetch(new Request("https://stage-pixel.example/health"), {
    ...valid,
    SUPABASE_URL: "https://ocyplckdojdubyrsxcxa.supabase.co",
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.service, "henvalt-pixel-collector-staging-no-send");
  assert.equal(body.configured, false);
  assert.equal(body.ok, false);
});
