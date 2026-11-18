import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isDateOnly, isValidDateRange } from "../supabase/functions/_shared/date-range-v2.mjs";

const merchant = readFileSync("supabase/functions/henvalt-merchant-dashboard/index.ts", "utf8");
const legacy = readFileSync("supabase/functions/henvalt-dashboard/index.ts", "utf8");

test("date-only validation rejects impossible Gregorian dates and malformed input", () => {
  for (const value of ["2026-02-29", "2026-04-31", "2026-13-01", "2026-1-01", "2026-01-01T00:00:00Z", ""]) {
    assert.equal(isDateOnly(value), false, value);
  }
  assert.equal(isDateOnly("2024-02-29"), true);
  assert.equal(isDateOnly("2026-11-18"), true);
});
test("date ranges are inclusive, ordered and bounded to 366 days", () => {
  assert.equal(isValidDateRange("2026-01-01", "2026-01-01"), true);
  assert.equal(isValidDateRange("2026-01-01", "2027-01-02"), true);
  assert.equal(isValidDateRange("2026-01-01", "2027-01-03"), false);
  assert.equal(isValidDateRange("2026-02-02", "2026-02-01"), false);
  assert.equal(isValidDateRange("2026-02-31", "2026-03-01"), false);
});
test("both dashboard endpoints use the shared strict date-only contract", () => {
  assert.match(merchant, /isDateOnly/);
  assert.match(merchant, /isValidDateRange\(from,to,366\)/);
  assert.match(legacy, /isDateOnly/);
  assert.match(legacy, /isValidDateRange\(from,to,366\)/);
  assert.doesNotMatch(merchant, /!Number\.isNaN\(Date\.parse\(v\)\)/);
});
