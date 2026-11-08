"use client";

import { SlidersHorizontalIcon } from "lucide-react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useTransition } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import type { FilterContext } from "@/lib/data/filter-context";
import {
  defaultPeriod,
  filtersHref,
  isDefault,
  isValidIsoDate,
  parseFilters,
  presets,
  type Channel,
  type Filters,
} from "@/lib/filters";
import { formatDate } from "@/lib/format";

const ALL = "__all__";
const CUSTOM = "__custom__";

type Props = { context: Pick<FilterContext, "range" | "regions" | "categories" | "options"> };

/** Reads the filters from the URL and writes every change back to it. Needs <Suspense>. */
export function FilterControls({ context }: Props) {
  const searchParams = useSearchParams();
  const pathname = usePathname();
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  const filters = parseFilters(searchParams, context.range, context.options);
  const activeCount =
    Number(filters.channel !== null) + Number(filters.region !== null) + Number(filters.category !== null);

  function update(patch: Partial<Filters>) {
    const next = { ...filters, ...patch };
    startTransition(() => {
      router.replace(filtersHref(pathname, next, context.range), { scroll: false });
    });
  }

  const fields = <FilterFields context={context} filters={filters} update={update} />;
  const reset = !isDefault(filters, context.range) && (
    <Button variant="ghost" size="sm" onClick={() => update({ ...defaultPeriod(context.range), channel: null, region: null, category: null })}>
      Wyczyść filtry
    </Button>
  );

  return (
    <div aria-busy={pending} className="flex flex-col gap-2">
      {/* Desktop: fields inline. */}
      <div className="hidden flex-wrap items-end gap-3 lg:flex">
        {fields}
        {reset}
      </div>
      {/* Phone/tablet: summary + panel. */}
      <div className="flex items-center justify-between gap-2 lg:hidden">
        <p className="text-sm text-muted-foreground">
          {formatDate(filters.from)} – {formatDate(filters.to)}
          {activeCount > 0 && ` · ${activeCount} ${activeCount === 1 ? "filtr" : "filtry"}`}
        </p>
        <Sheet>
          <SheetTrigger render={<Button variant="outline" size="sm" />}>
            <SlidersHorizontalIcon /> Filtry
          </SheetTrigger>
          <SheetContent side="bottom" className="flex flex-col gap-4 p-4">
            <SheetHeader className="p-0">
              <SheetTitle>Filtry</SheetTitle>
            </SheetHeader>
            <div className="flex flex-col gap-3">{fields}</div>
            {reset}
          </SheetContent>
        </Sheet>
      </div>
    </div>
  );
}

function FilterFields({
  context,
  filters,
  update,
}: Props & { filters: Filters; update: (patch: Partial<Filters>) => void }) {
  const { range } = context;
  const presetList = presets(range);
  const matching = presetList.find((p) => p.from === filters.from && p.to === filters.to);

  const periodItems = [
    ...presetList.map((p) => ({ value: p.id, label: p.label })),
    { value: CUSTOM, label: "Własny zakres" },
  ];
  const channelItems = [
    { value: ALL, label: "Wszystkie kanały" },
    { value: "store", label: "Sklepy stacjonarne" },
    { value: "online", label: "Sklep internetowy" },
  ];
  const regionItems = [
    { value: ALL, label: "Wszystkie województwa" },
    ...context.regions.map((r) => ({ value: r.code, label: r.name })),
  ];
  const categoryItems = [
    { value: ALL, label: "Wszystkie kategorie" },
    ...context.categories.map((c) => ({ value: c.code, label: c.name })),
  ];

  return (
    <>
      <Field label="Okres" id="f-okres">
        <Select
          items={periodItems}
          value={matching?.id ?? CUSTOM}
          onValueChange={(v) => {
            const p = presetList.find((x) => x.id === v);
            if (p) update({ from: p.from, to: p.to });
          }}
        >
          <SelectTrigger id="f-okres" className="w-full lg:w-48">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {periodItems.map((i) => (
              <SelectItem key={i.value} value={i.value} disabled={i.value === CUSTOM}>
                {i.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </Field>
      <Field label="Od" id="f-od">
        <Input
          id="f-od"
          type="date"
          className="w-full lg:w-40"
          min={range.min}
          max={filters.to}
          value={filters.from}
          onChange={(e) => {
            const from = e.target.value;
            // Moving the start past the end drags the end along instead of resetting both.
            if (isValidIsoDate(from)) update({ from, to: from > filters.to ? from : filters.to });
          }}
        />
      </Field>
      <Field label="Do" id="f-do">
        <Input
          id="f-do"
          type="date"
          className="w-full lg:w-40"
          min={filters.from}
          max={range.max}
          value={filters.to}
          onChange={(e) => {
            const to = e.target.value;
            if (isValidIsoDate(to)) update({ to, from: to < filters.from ? to : filters.from });
          }}
        />
      </Field>
      <SelectField
        label="Kanał"
        id="f-kanal"
        items={channelItems}
        value={filters.channel ?? ALL}
        onChange={(v) => update({ channel: v === ALL ? null : (v as Channel) })}
      />
      <SelectField
        label="Województwo"
        id="f-region"
        items={regionItems}
        value={filters.region ?? ALL}
        onChange={(v) => update({ region: v === ALL ? null : v })}
      />
      <SelectField
        label="Kategoria"
        id="f-kategoria"
        items={categoryItems}
        value={filters.category ?? ALL}
        onChange={(v) => update({ category: v === ALL ? null : v })}
      />
    </>
  );
}

function Field({ label, id, children }: { label: string; id: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={id} className="text-xs text-muted-foreground">
        {label}
      </Label>
      {children}
    </div>
  );
}

function SelectField({
  label,
  id,
  items,
  value,
  onChange,
}: {
  label: string;
  id: string;
  items: { value: string; label: string }[];
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <Field label={label} id={id}>
      <Select items={items} value={value} onValueChange={(v) => v !== null && onChange(String(v))}>
        <SelectTrigger id={id} className="w-full lg:w-52">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {items.map((i) => (
            <SelectItem key={i.value} value={i.value}>
              {i.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </Field>
  );
}
