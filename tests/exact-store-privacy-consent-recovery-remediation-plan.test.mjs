import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("exact-store remediation plan defines fail-closed identity and same-store lineage", () => {
  const doc = readFileSync(
    new URL("../docs/exact-store-privacy-consent-recovery-remediation-plan.md", import.meta.url),
    "utf8",
  );

  for (const required of [
    "immutable internal",
    "Fail-closed rule",
    "shopify_connection_id",
    "Do not silently backfill legacy rows",
    "Shopify consent and an unsubscribe token",
    "Shop redaction must not delete the HENVALT tenant",
    "same connection",
    "POSSIBLE/customer-only matches remain non-billable",
    "Stage A",
    "Stage F",
    "Mandatory regression matrix",
    "Unlinked/uninstalled shop privacy request",
    "No Supabase migration or function was applied",
  ]) {
    assert.ok(doc.includes(required), `Missing remediation contract: ${required}`);
  }
});

test("exact-store remediation plan never authorizes production changes", () => {
  const doc = readFileSync(
    new URL("../docs/exact-store-privacy-consent-recovery-remediation-plan.md", import.meta.url),
    "utf8",
  );
  assert.match(doc, /design\/preparation only/i);
  assert.match(doc, /requires separate explicit authorization/i);
  assert.match(doc, /No production DDL or function replacement is authorized/i);
});
