import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("secondary function lineage audit records scheduler, conversation and billing risks", () => {
  const audit = readFileSync(
    new URL("../docs/secondary-function-lineage-audit.md", import.meta.url),
    "utf8",
  );

  for (const required of [
    "schedule_next_recovery_intervention",
    "process_mailersend_inbound_reply",
    "unsubscribe_customer_by_token",
    "control_plane_billing_summary",
    "control_plane_revenue_series",
    "measure_billing_entry",
    "same-connection",
    "tenant-wide opt-out",
    "Store-specific billing summary/revenue series",
    "No migration was applied",
  ]) {
    assert.ok(audit.includes(required), `Missing audited contract: ${required}`);
  }
});
