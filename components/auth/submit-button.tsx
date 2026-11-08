"use client";

import { useFormStatus } from "react-dom";

import { Button } from "@/components/ui/button";

type Props = React.ComponentProps<typeof Button> & { pendingLabel: string };

/** A submit button that disables itself and shows `pendingLabel` while the form posts. */
export function SubmitButton({ children, pendingLabel, ...props }: Props) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" disabled={pending} aria-busy={pending} {...props}>
      {pending ? pendingLabel : children}
    </Button>
  );
}
