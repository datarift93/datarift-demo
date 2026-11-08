import Link from "next/link";
import { Suspense } from "react";

import { FilterBar, FilterBarSkeleton } from "@/components/filters/filter-bar";
import { MobileNav } from "@/components/shell/mobile-nav";
import { NavLinks, NavLinksStatic } from "@/components/shell/nav-links";
import { DemoBanner, UserMenu } from "@/components/shell/user-menu";
import { Skeleton } from "@/components/ui/skeleton";

function UserMenuSkeleton() {
  return (
    <div className="flex flex-col gap-2" aria-hidden>
      <Skeleton className="h-4 w-28" />
      <Skeleton className="h-4 w-40" />
      <Skeleton className="h-8 w-20" />
    </div>
  );
}

/**
 * App shell for every signed-in view. The static frame (menu, layout) prerenders; anything
 * that reads the session or the URL streams in behind its own <Suspense> boundary.
 */
export default function AppLayout({ children }: LayoutProps<"/">) {
  const userMenu = (
    <Suspense fallback={<UserMenuSkeleton />}>
      <UserMenu />
    </Suspense>
  );

  return (
    <div className="flex min-h-svh w-full">
      <aside className="sticky top-0 hidden h-svh w-60 shrink-0 flex-col gap-6 border-r p-4 md:flex">
        <Link href="/" className="px-3 text-sm font-semibold">
          Wisła · demo BI
        </Link>
        <Suspense fallback={<NavLinksStatic />}>
          <NavLinks />
        </Suspense>
        <div className="mt-auto border-t pt-4">{userMenu}</div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <Suspense>
          <DemoBanner />
        </Suspense>
        <header className="flex flex-col gap-3 border-b px-4 py-3 sm:px-6">
          <div className="flex items-center gap-2 md:hidden">
            <MobileNav userMenu={userMenu} />
            <span className="text-sm font-semibold">Wisła · demo BI</span>
          </div>
          <Suspense fallback={<FilterBarSkeleton />}>
            <FilterBar />
          </Suspense>
        </header>
        <main className="flex-1 px-4 py-6 sm:px-6">{children}</main>
      </div>
    </div>
  );
}
