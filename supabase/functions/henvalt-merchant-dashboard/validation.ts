export type DashboardGranularity = "day" | "week" | "month";

export type DashboardRange =
  | { ok: true; from: string; to: string; granularity: DashboardGranularity }
  | { ok: false; error: "invalid_date" | "invalid_date_range" | "invalid_granularity" };

export function isIsoCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day;
}

export function resolveDashboardRange(
  fromParam: string | null,
  toParam: string | null,
  granularityParam: string | null,
  today: string,
  defaultFrom: string,
): DashboardRange {
  if (!isIsoCalendarDate(today) || !isIsoCalendarDate(defaultFrom)) {
    return { ok: false, error: "invalid_date" };
  }
  if (fromParam !== null && !isIsoCalendarDate(fromParam)) {
    return { ok: false, error: "invalid_date" };
  }
  if (toParam !== null && !isIsoCalendarDate(toParam)) {
    return { ok: false, error: "invalid_date" };
  }
  const from = fromParam ?? defaultFrom;
  const to = toParam ?? today;
  if (to < from) return { ok: false, error: "invalid_date_range" };
  const fromMs = Date.parse(from + "T00:00:00.000Z");
  const toMs = Date.parse(to + "T00:00:00.000Z");
  if (toMs - fromMs > 366 * 86400000) {
    return { ok: false, error: "invalid_date_range" };
  }
  const granularity = granularityParam ?? "day";
  if (granularity !== "day" && granularity !== "week" && granularity !== "month") {
    return { ok: false, error: "invalid_granularity" };
  }
  return { ok: true, from, to, granularity };
}
