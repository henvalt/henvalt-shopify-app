import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("store isolation matrix covers cross-store identity, privacy and billing without assuming billing principal", () => {
  const matrix = readFileSync(
    new URL("../docs/store-isolation-regression-matrix.md", import.meta.url),
    "utf8",
  );

  for (const required of [
    "OAUTH-01",
    "WEB-07",
    "DATA-01",
    "REC-03",
    "ATTR-03",
    "PRIV-03",
    "UNSUB-01",
    "PIX-01",
    "MIG-07",
    "Billing decision gate",
    "per-store, per-tenant, or hybrid",
    "This matrix is a test specification",
  ]) {
    assert.ok(matrix.includes(required), `Missing regression requirement: ${required}`);
  }
  assert.doesNotMatch(matrix, /Separate store-scoped billing accounts\/subscription IDs/);
});
