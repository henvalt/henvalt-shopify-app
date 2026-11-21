import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const design = readFileSync(
  new URL("../docs/app-aware-shopify-identity-migration-design-review-only.md", import.meta.url),
  "utf8",
);

test("migration design is review-only and preserves production release boundary", () => {
  for (const phrase of [
    "review-only engineering design",
    "No SQL was applied",
    "shopify_connections.shop_domain",
    "shopify_oauth_states",
    "webhook_events",
    "canonical_events",
    "pixel_keys.shopify_connection_id",
    "Do not backfill from active=true",
    "no fallback to the legacy secret or resolver",
    "separate explicit production release authorization",
    "must not be passed to Supabase apply_migration",
  ]) {
    assert.ok(design.includes(phrase), `migration design missing: ${phrase}`);
  }
});

test("migration design defers derived graph and billing until lineage and policy are ready", () => {
  for (const phrase of [
    "customers, sessions, session aliases, checkouts",
    "recovery sequences and interventions",
    "delivery requests and attempts",
    "privacy request/receipt lineage",
    "billing only after billing principal decision",
    "isolated two-store fixtures",
  ]) {
    assert.ok(design.includes(phrase), `migration sequencing missing: ${phrase}`);
  }
  assert.match(design, /Rollback before traffic switch/);
});
