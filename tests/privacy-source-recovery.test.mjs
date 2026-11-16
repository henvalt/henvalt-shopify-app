import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(
  new URL("../supabase/functions/henvalt-shopify-privacy/index.ts", import.meta.url),
  "utf8",
);

test("deployed privacy handler source snapshot is versioned and clearly non-deployed", () => {
  assert.match(source, /Source recovery snapshot of deployed Supabase Edge Function/);
  assert.match(source, /Deployed version at capture: 1/);
  assert.match(source, /Deployed source SHA-256: 213af659378fd3da90b8edbfce12347445e4f5ce633ca6bf6705f8d3cae3e5f4/);
  assert.match(source, /This file is not deployed by this commit/);
});

test("privacy snapshot preserves verified raw-body HMAC and all mandatory topics", () => {
  assert.match(source, /const raw = await req\.text\(\)/);
  assert.match(source, /verifyHmac\(raw, hmac\)/);
  for (const topic of ["customers/data_request", "customers/redact", "shop/redact"]) {
    assert.ok(source.includes(topic), `Missing compliance topic: ${topic}`);
  }
  assert.match(source, /status: matched \? "PENDING" : "REVIEW_REQUIRED"/);
});
