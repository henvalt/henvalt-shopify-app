import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202611220003_shopify_privacy_retention_cron.sql", "utf8");

test("privacy retention minimizes stale requests and expires export bundles", () => {
  assert.match(sql, /interval '7 days'/i);
  assert.match(sql, /status = 'REVIEW_REQUIRED'/i);
  assert.match(sql, /payload = '\\{\\}'::jsonb/i);
  assert.match(sql, /result_payload = null/i);
  assert.match(sql, /result_expires_at <= now\\(\\)/i);
});

test("privacy retention cron is daily and idempotently named", () => {
  assert.match(sql, /henvalt-shopify-privacy-retention/);
  assert.match(sql, /'17 3 \\* \\* \\*'/);
  assert.match(sql, /cron\\.schedule/);
});
