"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Suspense } from "react";

type Props = Omit<React.ComponentProps<typeof Link>, "href"> & { href: string };

function WithQuery({ href, ...props }: Props) {
  const query = useSearchParams().toString();
  return <Link href={query ? `${href}?${query}` : href} {...props} />;
}

/**
 * A link inside a view that keeps the global filters (the current query string), so moving
 * between views never resets them. Falls back to the plain link while the URL streams in.
 */
export function FilterLink(props: Props) {
  return (
    <Suspense fallback={<Link {...props} />}>
      <WithQuery {...props} />
    </Suspense>
  );
}
