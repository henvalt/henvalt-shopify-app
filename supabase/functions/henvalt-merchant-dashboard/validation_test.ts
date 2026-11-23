import {
  isIsoCalendarDate,
  resolveDashboardRange,
} from "./validation.ts";

Deno.test("accepts valid Gregorian dates including leap day", () => {
  if (!isIsoCalendarDate("2024-02-29")) throw new Error("valid leap day rejected");
  if (!isIsoCalendarDate("2026-11-23")) throw new Error("valid date rejected");
});

Deno.test("rejects impossible dates and malformed formats", () => {
  for (const value of ["2026-02-29", "2026-02-31", "2026-13-01", "2026-2-01", "2026/11/23"]) {
    if (isIsoCalendarDate(value)) throw new Error("accepted invalid date: " + value);
  }
});

Deno.test("uses defaults only when parameters are omitted", () => {
  const result = resolveDashboardRange(null, null, null, "2026-11-23", "2026-10-25");
  if (!result.ok || result.from !== "2026-10-25" || result.to !== "2026-11-23" ||
    result.granularity !== "day") throw new Error("default range mismatch");
});

Deno.test("rejects malformed explicit from date instead of silently defaulting", () => {
  const result = resolveDashboardRange("2026-02-31", null, null, "2026-11-23", "2026-10-25");
  if (result.ok || result.error !== "invalid_date") throw new Error("invalid from date accepted");
});

Deno.test("rejects malformed explicit to date instead of silently defaulting", () => {
  const result = resolveDashboardRange(null, "2026-04-31", null, "2026-11-23", "2026-10-25");
  if (result.ok || result.error !== "invalid_date") throw new Error("invalid to date accepted");
});

Deno.test("rejects reversed and overlong ranges", () => {
  const reversed = resolveDashboardRange("2026-11-24", "2026-11-23", null, "2026-11-23", "2026-10-25");
  const overlong = resolveDashboardRange("2025-11-22", "2026-11-23", null, "2026-11-23", "2026-10-25");
  if (reversed.ok || reversed.error !== "invalid_date_range") throw new Error("reversed range accepted");
  if (overlong.ok || overlong.error !== "invalid_date_range") throw new Error("overlong range accepted");
});

Deno.test("accepts each supported granularity", () => {
  for (const granularity of ["day", "week", "month"]) {
    const result = resolveDashboardRange(null, null, granularity, "2026-11-23", "2026-10-25");
    if (!result.ok || result.granularity !== granularity) throw new Error("granularity rejected: " + granularity);
  }
});

Deno.test("rejects unsupported explicit granularity", () => {
  const result = resolveDashboardRange(null, null, "year", "2026-11-23", "2026-10-25");
  if (result.ok || result.error !== "invalid_granularity") throw new Error("unsupported granularity accepted");
});
