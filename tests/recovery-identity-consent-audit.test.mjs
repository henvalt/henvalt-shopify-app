import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("recovery identity and consent audit captures tenant-only isolation risks", () => {
  const audit = readFileSync(
    new URL("../docs/recovery-identity-consent-function-audit.md", import.meta.url),
    "utf8",
  );
  for (const required of [
    "resolve_identity(p_event_id)",
    "evaluate_eligibility(p_opportunity_id)",
    "evaluate_communication_eligibility",
    "stop_recovery_after_order(p_attribution_id)",
    "IDENTITY-01",
    "IDENTITY-02",
    "ELIG-01",
    "CONS-03",
    "PROC-01",
    "STOP-01",
    "PRIV-06",
    "Ambiguous/unresolved",
  ]) {
    assert.ok(audit.includes(required), `Missing audit requirement: ${required}`);
  }
});
