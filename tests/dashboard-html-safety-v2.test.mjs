import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dashboard = readFileSync("dashboard/index.html", "utf8");

test("dashboard escapes merchant-controlled and event-derived values before HTML insertion", () => {
  assert.match(dashboard, /function esc\(s\)=>String\(s\?\?""\)\.replace/);
  assert.match(dashboard, /esc\(s\.id\)/);
  assert.match(dashboard, /esc\(s\.shop_domain\)/);
  assert.match(dashboard, /esc\(x\.eventType\)/);
  assert.match(dashboard, /esc\(x\.summary\)/);
  assert.match(dashboard, /esc\(x\.outcome\|\|"pending"\)/);
  assert.match(dashboard, /esc\(e\?\.message/);
});
test("dashboard renders recovery values as text or escaped markup, never executes event HTML", () => {
  assert.match(dashboard, /\.textContent=/);
  assert.doesNotMatch(dashboard, /innerHTML\s*=\s*[^;\n]*\+\s*(?:x|s)\.(?:summary|eventType|shop_domain|id)/);
  assert.doesNotMatch(dashboard, /eval\s*\(|new Function\s*\(/);
});
test("dashboard never inserts API-provided recipient email or provider token fields", () => {
  assert.doesNotMatch(dashboard, /recipient_email|mailer_send_api_token|shopify_access_token/);
});
