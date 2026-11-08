// Polish display formats used across the UI.
// Intl uses a non-breaking space (U+00A0) as the thousands separator and before "zł",
// so amounts never wrap in the middle of a number.

const TIME_ZONE = "Europe/Warsaw";

const currencyFormatter = new Intl.NumberFormat("pl-PL", {
  style: "currency",
  currency: "PLN",
  // pl-PL skips grouping for 4-digit numbers by default; tables read better with it always on.
  useGrouping: "always",
});

const integerFormatter = new Intl.NumberFormat("pl-PL", {
  maximumFractionDigits: 0,
  useGrouping: "always",
});

const dateFormatter = new Intl.DateTimeFormat("pl-PL", {
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  timeZone: TIME_ZONE,
});

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

const wholeCurrencyFormatter = new Intl.NumberFormat("pl-PL", {
  style: "currency",
  currency: "PLN",
  maximumFractionDigits: 0,
  useGrouping: "always",
});

const compactFormatter = new Intl.NumberFormat("pl-PL", { notation: "compact", maximumFractionDigits: 1 });

/** 1234567.89 -> "1 234 567,89 zł"; with `{ whole: true }` -> "1 234 568 zł" (big headline values). */
export function formatPLN(value: number, { whole = false }: { whole?: boolean } = {}): string {
  return (whole ? wholeCurrencyFormatter : currencyFormatter).format(value);
}

/** Axis ticks: 1234567 -> "1,2 mln zł", 350000 -> "350 tys. zł". */
export function formatPLNCompact(value: number): string {
  return `${compactFormatter.format(value)} zł`;
}

/** 1234567 -> "1 234 567" */
export function formatInteger(value: number): string {
  return integerFormatter.format(value);
}

/**
 * Ratio to percent: 0.123 -> "12,3%".
 * With `signed`, positive values get a "+" (for changes vs the previous period).
 */
export function formatPercent(
  ratio: number,
  { digits = 1, signed = false }: { digits?: number; signed?: boolean } = {},
): string {
  return new Intl.NumberFormat("pl-PL", {
    style: "percent",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
    signDisplay: signed ? "exceptZero" : "auto",
  }).format(ratio);
}

/**
 * "2026-11-02" or a Date -> "02.11.2026".
 * Plain ISO dates (as Postgres returns `date` columns) are reformatted without
 * going through Date, so no time zone can shift them by a day.
 */
export function formatDate(value: string | Date): string {
  if (typeof value === "string") {
    const match = ISO_DATE.exec(value);
    if (match) {
      const [, year, month, day] = match;
      return `${day}.${month}.${year}`;
    }
    value = new Date(value);
  }
  if (Number.isNaN(value.getTime())) {
    throw new RangeError(`Invalid date: ${String(value)}`);
  }
  return dateFormatter.format(value);
}

const dateTimeFormatter = new Intl.DateTimeFormat("pl-PL", {
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: TIME_ZONE,
});

/** Timestamp -> "08.11.2026, 10:15" in Warsaw time. */
export function formatDateTime(value: string | Date): string {
  const d = typeof value === "string" ? new Date(value) : value;
  if (Number.isNaN(d.getTime())) {
    throw new RangeError(`Invalid date: ${String(value)}`);
  }
  return dateTimeFormatter.format(d);
}

/** Seconds -> "8,4 s", "2 min 4 s", "1 h 3 min". */
export function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 1 }).format(seconds)} s`;
  }
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h} h ${m} min` : `${m} min ${s} s`;
}
