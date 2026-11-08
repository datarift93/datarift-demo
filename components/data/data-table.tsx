"use client";

import { ArrowDownIcon, ArrowUpDownIcon, ArrowUpIcon } from "lucide-react";
import { useMemo, useState } from "react";

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";

import { EmptyState } from "./states";

export type Column<Row> = {
  key: string;
  header: string;
  /** Cell content; defaults to String(row[key]). */
  cell?: (row: Row) => React.ReactNode;
  /** Value used for sorting; defaults to row[key]. Omit `sortable` to disable. */
  sortValue?: (row: Row) => string | number | null;
  sortable?: boolean;
  align?: "left" | "right";
  className?: string;
};

type Sort = { key: string; dir: "asc" | "desc" };

const collator = new Intl.Collator("pl", { numeric: true, sensitivity: "base" });

function compare(a: string | number | null, b: string | number | null): number {
  if (a === b) return 0;
  if (a === null) return 1; // empty values last
  if (b === null) return -1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  return collator.compare(String(a), String(b));
}

/**
 * Table with click-to-sort headers (Polish collation, empty values last), horizontal
 * scroll on narrow screens and an empty state. For datasets already loaded in full.
 */
export function DataTable<Row>({
  columns,
  rows,
  rowKey,
  initialSort,
  empty = "Brak danych dla wybranych filtrów.",
  caption,
}: {
  columns: Column<Row>[];
  rows: Row[];
  rowKey: (row: Row) => string | number;
  initialSort?: Sort;
  empty?: string;
  caption?: string;
}) {
  const [sort, setSort] = useState<Sort | undefined>(initialSort);

  const sorted = useMemo(() => {
    if (!sort) return rows;
    const col = columns.find((c) => c.key === sort.key);
    if (!col) return rows;
    const value = col.sortValue ?? ((r: Row) => (r as Record<string, string | number | null>)[col.key]);
    const out = [...rows].sort((a, b) => compare(value(a), value(b)));
    return sort.dir === "desc" ? out.reverse() : out;
  }, [rows, columns, sort]);

  if (rows.length === 0) return <EmptyState message={empty} />;

  function toggle(key: string) {
    setSort((s) => (s?.key === key ? { key, dir: s.dir === "asc" ? "desc" : "asc" } : { key, dir: "asc" }));
  }

  return (
    <div className="overflow-x-auto rounded-lg border">
      <Table>
        {caption && <caption className="sr-only">{caption}</caption>}
        <TableHeader>
          <TableRow>
            {columns.map((col) => {
              const active = sort?.key === col.key;
              const Icon = !active ? ArrowUpDownIcon : sort.dir === "asc" ? ArrowUpIcon : ArrowDownIcon;
              return (
                <TableHead
                  key={col.key}
                  aria-sort={active ? (sort.dir === "asc" ? "ascending" : "descending") : undefined}
                  className={cn(col.align === "right" && "text-right", col.className)}
                >
                  {col.sortable ? (
                    <button
                      type="button"
                      onClick={() => toggle(col.key)}
                      className={cn(
                        "inline-flex items-center gap-1 hover:text-foreground",
                        col.align === "right" && "flex-row-reverse",
                      )}
                    >
                      {col.header}
                      <Icon className={cn("size-3.5", !active && "opacity-40")} aria-hidden />
                    </button>
                  ) : (
                    col.header
                  )}
                </TableHead>
              );
            })}
          </TableRow>
        </TableHeader>
        <TableBody>
          {sorted.map((row) => (
            <TableRow key={rowKey(row)}>
              {columns.map((col) => (
                <TableCell
                  key={col.key}
                  className={cn(col.align === "right" && "text-right tabular-nums", col.className)}
                >
                  {col.cell ? col.cell(row) : String((row as Record<string, unknown>)[col.key] ?? "")}
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
