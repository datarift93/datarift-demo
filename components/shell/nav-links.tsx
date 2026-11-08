"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";

import { cn } from "@/lib/utils";
import { NAV_ITEMS } from "@/lib/navigation";

type Props = { onNavigate?: () => void };

function Links({
  query,
  pathname,
  onNavigate,
}: {
  query: string;
  pathname: string | null;
  onNavigate?: () => void;
}) {
  return (
    <nav aria-label="Widoki" className="flex flex-col gap-1">
      {NAV_ITEMS.map((item) => {
        const active = pathname !== null && (pathname === item.href || pathname.startsWith(`${item.href}/`));
        return (
          <Link
            key={item.href}
            href={query ? `${item.href}?${query}` : item.href}
            onClick={onNavigate}
            aria-current={active ? "page" : undefined}
            className={cn(
              "rounded-md px-3 py-2 text-sm transition-colors hover:bg-muted",
              active ? "bg-muted font-medium text-foreground" : "text-muted-foreground",
            )}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}

/** Menu links that carry the current filters to the next view. Needs <Suspense>. */
export function NavLinks({ onNavigate }: Props) {
  const query = useSearchParams().toString();
  const pathname = usePathname();
  return <Links query={query} pathname={pathname} onNavigate={onNavigate} />;
}

/**
 * Same menu without filters or active state, used as the Suspense fallback. It reads no
 * URL data, so it prerenders even on dynamic routes like /importy/[id].
 */
export function NavLinksStatic() {
  return <Links query="" pathname={null} />;
}
