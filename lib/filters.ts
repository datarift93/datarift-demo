// Global filters (period, channel, region, category) kept in the URL, so a link
// reproduces the same view (requirements F1). Pure functions: no React, no I/O.
//
// URL parameters are Polish, like the rest of the UI:
//   ?od=2025-10-01&do=2025-12-31&kanal=online&region=14&kategoria=HOME
// Values equal to the defaults are left out, so the default view has a clean URL.

export type Channel = "store" | "online";

export type Filters = {
  from: string; // YYYY-MM-DD, inclusive
  to: string; // YYYY-MM-DD, inclusive
  channel: Channel | null;
  region: string | null; // region_code (TERYT)
  category: string | null; // category_code
};

/** First and last day with data (YYYY-MM-DD). */
export type DataRange = { min: string; max: string };

export type FilterOptions = {
  regions: readonly string[];
  categories: readonly string[];
};

export const PARAMS = {
  from: "od",
  to: "do",
  channel: "kanal",
  region: "region",
  category: "kategoria",
} as const;

const CHANNEL_TO_PARAM: Record<Channel, string> = { store: "sklepy", online: "online" };
const PARAM_TO_CHANNEL: Record<string, Channel> = { sklepy: "store", online: "online" };

type ParamSource = URLSearchParams | Record<string, string | string[] | undefined>;

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

// ---------------------------------------------------------------- dates (UTC, no time zone shifts)

function toDate(iso: string): Date {
  return new Date(`${iso}T00:00:00Z`);
}

function toIso(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function isValidIsoDate(value: string): boolean {
  if (!ISO_DATE.test(value)) return false;
  const d = toDate(value);
  // "2025-13-01" is an Invalid Date; "2025-02-30" rolls over to March and fails the compare.
  return !Number.isNaN(d.getTime()) && toIso(d) === value;
}

export function addDays(iso: string, days: number): string {
  const d = toDate(iso);
  d.setUTCDate(d.getUTCDate() + days);
  return toIso(d);
}

/** First day of the month `months` months before the month of `iso` (0 = same month). */
export function monthStart(iso: string, monthsBack = 0): string {
  const d = toDate(iso);
  return toIso(new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - monthsBack, 1)));
}

/** Number of days in [from, to], both included. */
export function periodDays(from: string, to: string): number {
  return Math.round((toDate(to).getTime() - toDate(from).getTime()) / 86_400_000) + 1;
}

function clamp(iso: string, range: DataRange): string {
  if (iso < range.min) return range.min;
  if (iso > range.max) return range.max;
  return iso;
}

// ---------------------------------------------------------------- defaults and presets

/** Default period: the last full quarter of data (three calendar months up to the last day). */
export function defaultPeriod(range: DataRange): { from: string; to: string } {
  return { from: clamp(monthStart(range.max, 2), range), to: range.max };
}

export type Preset = { id: string; label: string; from: string; to: string };

export function presets(range: DataRange): Preset[] {
  const firstYear = Number(range.min.slice(0, 4));
  const lastYear = Number(range.max.slice(0, 4));
  const years: Preset[] = [];
  for (let y = lastYear; y >= firstYear; y--) {
    years.push({
      id: `rok-${y}`,
      label: `Rok ${y}`,
      from: clamp(`${y}-01-01`, range),
      to: clamp(`${y}-12-31`, range),
    });
  }
  return [
    { id: "30-dni", label: "Ostatnie 30 dni", from: clamp(addDays(range.max, -29), range), to: range.max },
    { id: "kwartal", label: "Ostatnie 3 miesiące", ...defaultPeriod(range) },
    { id: "12-miesiecy", label: "Ostatnie 12 miesięcy", from: clamp(monthStart(range.max, 11), range), to: range.max },
    ...years,
    { id: "calosc", label: "Cały okres", from: range.min, to: range.max },
  ];
}

/** The period of the same length directly before [from, to] (for "change vs previous period"). */
export function previousPeriod(from: string, to: string): { from: string; to: string } {
  const days = periodDays(from, to);
  return { from: addDays(from, -days), to: addDays(from, -1) };
}

// ---------------------------------------------------------------- URL <-> filters

function read(params: ParamSource, key: string): string | null {
  const value = params instanceof URLSearchParams ? params.get(key) : params[key];
  const single = Array.isArray(value) ? value[0] : value;
  const trimmed = single?.trim();
  return trimmed ? trimmed : null;
}

/**
 * Filters from the URL. Anything invalid falls back to the default instead of failing:
 * a hand-edited or outdated link still opens a sensible view.
 */
export function parseFilters(params: ParamSource, range: DataRange, options?: FilterOptions): Filters {
  const defaults = defaultPeriod(range);

  let from = read(params, PARAMS.from);
  let to = read(params, PARAMS.to);
  from = from && isValidIsoDate(from) ? clamp(from, range) : defaults.from;
  to = to && isValidIsoDate(to) ? clamp(to, range) : defaults.to;
  if (from > to) ({ from, to } = defaults);

  const channelParam = read(params, PARAMS.channel);
  const channel = channelParam ? (PARAM_TO_CHANNEL[channelParam] ?? null) : null;

  const region = read(params, PARAMS.region);
  const category = read(params, PARAMS.category);

  return {
    from,
    to,
    channel,
    region: region && (!options || options.regions.includes(region)) ? region : null,
    category: category && (!options || options.categories.includes(category)) ? category : null,
  };
}

/** URL parameters for `filters`, leaving out everything equal to the defaults. */
export function toSearchParams(filters: Filters, range: DataRange): URLSearchParams {
  const defaults = defaultPeriod(range);
  const out = new URLSearchParams();
  if (filters.from !== defaults.from || filters.to !== defaults.to) {
    out.set(PARAMS.from, filters.from);
    out.set(PARAMS.to, filters.to);
  }
  if (filters.channel) out.set(PARAMS.channel, CHANNEL_TO_PARAM[filters.channel]);
  if (filters.region) out.set(PARAMS.region, filters.region);
  if (filters.category) out.set(PARAMS.category, filters.category);
  return out;
}

/** `path` with the filters as a query string (no "?" when everything is default). */
export function filtersHref(path: string, filters: Filters, range: DataRange): string {
  const query = toSearchParams(filters, range).toString();
  return query ? `${path}?${query}` : path;
}

export function isDefault(filters: Filters, range: DataRange): boolean {
  return toSearchParams(filters, range).size === 0;
}
