import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(
  new URL("../docs/sql/internal-ingress-replay-claim-review-only.sql", import.meta.url),
  "utf8",
).toLowerCase();

test("replay claim candidate is review-only and private", () => {
  assert.match(sql, /review only/);
  assert.match(sql, /create table if not exists henvalt\.internal_ingress_requests/);
  assert.match(sql, /request_id uuid primary key/);
  assert.match(sql, /enable row level security/);
  assert.match(sql, /revoke all on table henvalt\.internal_ingress_requests\s+from public, anon, authenticated, service_role/);
});

test("claim RPC is atomic, time-bounded, and service-role only", () => {
  assert.match(sql, /create or replace function henvalt\.claim_internal_ingress_request/);
  assert.match(sql, /security definer/);
  assert.match(sql, /set search_path = pg_catalog, henvalt/);
  assert.match(sql, /p_signed_at < clock_timestamp\(\) - interval '5 minutes'/);
  assert.match(sql, /p_signed_at > clock_timestamp\(\) \+ interval '5 minutes'/);
  assert.match(sql, /on conflict \(request_id\) do nothing/);
  assert.match(sql, /return v_inserted = 1/);
  assert.match(sql, /received_at < clock_timestamp\(\) - interval '7 days'/);
  assert.match(sql, /limit 500/);
  assert.match(sql, /revoke all on function henvalt\.claim_internal_ingress_request\(uuid, timestamptz\)\s+from public, anon, authenticated/);
  assert.match(sql, /grant execute on function henvalt\.claim_internal_ingress_request\(uuid, timestamptz\)\s+to service_role/);
  assert.doesNotMatch(sql, /grant .* on table henvalt\.internal_ingress_requests to anon/);
});
