"use client";

import { MenuIcon } from "lucide-react";
import { Suspense, useState } from "react";

import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";

import { NavLinks, NavLinksStatic } from "./nav-links";

/** Menu in a slide-out panel on phones (< md). `userMenu` is rendered on the server. */
export function MobileNav({ userMenu }: { userMenu: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger render={<Button variant="ghost" size="icon" aria-label="Otwórz menu" />}>
        <MenuIcon />
      </SheetTrigger>
      <SheetContent side="left" className="flex w-72 flex-col gap-6 p-4">
        <SheetHeader className="p-0">
          <SheetTitle>Wisła · demo BI</SheetTitle>
        </SheetHeader>
        <Suspense fallback={<NavLinksStatic />}>
          <NavLinks onNavigate={() => setOpen(false)} />
        </Suspense>
        <div className="mt-auto border-t pt-4">{userMenu}</div>
      </SheetContent>
    </Sheet>
  );
}
