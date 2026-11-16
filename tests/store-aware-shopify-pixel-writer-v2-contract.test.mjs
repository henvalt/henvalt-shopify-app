import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const contract = readFileSync(
  new URL("../docs/store-aware-shopify-pixel-writer-v2-contract.md", import.meta.url),
  "utf8"
);

test("pixel V2 contract preserves the trusted pixel-key connection boundary", () => {
  assert.match(contract, /pixel_keys\.shopify_connection_id/);
  assert.match(contract, /browser must never supply the authoritative tenant ID, connection ID or app key/i);
  assert.match(contract, /require exactly one matching active key\/connection\/origin tuple/i);
});

test("pixel V2 contract requires connection-scoped customer, session, alias and checkout resolution", () => {
  for (const name of ["canonical_events", "customers", "sessions", "session_aliases", "checkouts"]) {
    assert.match(contract, new RegExp(name));
  }
  assert.match(contract, /must never use email as a cross-store identity key/i);
  assert.match(contract, /must not fall back to V1 tenant-wide resolution/i);
});

test("pixel V2 contract blocks unsafe uniqueness changes and historical backfills", () => {
  assert.match(contract, /current live unique constraints are tenant-only/i);
  assert.match(contract, /Do not enable V2 writes[\s\S]*?until every affected writer has been inventoried and migrated/i);
  assert.match(contract, /Do not backfill historical connection IDs from metadata, email, current pixel keys/i);
  assert.match(contract, /feature flag/i);
});

test("pixel V2 contract includes two-store collision and consent regressions", () => {
  for (const phrase of [
    "Same pixel event ID in Store A and Store B",
    "Same Shopify customer ID in A and B",
    "Same normalized email in A and B",
    "Same client/session reference in A and B",
    "Same checkout/cart alias in A and B",
    "Analytics consent disabled"
  ]) {
    assert.ok(contract.includes(phrase), `Missing regression case: ${phrase}`);
  }
});

test("pixel V2 contract keeps recovery and production cutover explicitly gated", () => {
  assert.match(contract, /must not enter recovery, delivery, attribution or billing queues/i);
  assert.match(contract, /No production DDL\/DML, backfill, function replacement/i);
});
