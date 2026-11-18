/** Validate a canonical Gregorian YYYY-MM-DD date without Date.parse rollover. */
export function isDateOnly(value) {
  if (typeof value !== "string" || !/^\\d{4}-\\d{2}-\\d{2}$/.test(value)) return false;
  const parsed = new Date(value + "T00:00:00.000Z");
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/** Validate an inclusive UTC date-only range and cap its span. */
export function isValidDateRange(from, to, maxDays = 366) {
  if (!isDateOnly(from) || !isDateOnly(to) ||
      !Number.isSafeInteger(maxDays) || maxDays < 0) return false;
  const start = Date.parse(from + "T00:00:00.000Z");
  const end = Date.parse(to + "T00:00:00.000Z");
  return end >= start && end - start <= maxDays * 86400000;
}
