import { PageHeader } from "./states";

/** A view that is planned but not built yet: says what will be here and when. */
export function ViewPlaceholder({
  title,
  description,
  stage,
  features,
}: {
  title: string;
  description: string;
  stage: string;
  features: string[];
}) {
  return (
    <>
      <PageHeader title={title} description={description} />
      <div className="max-w-2xl rounded-lg border border-dashed p-6">
        <p className="text-sm font-medium">Ten widok powstaje w etapie: {stage}</p>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-muted-foreground">
          {features.map((f) => (
            <li key={f}>{f}</li>
          ))}
        </ul>
        <p className="mt-4 text-sm text-muted-foreground">
          Filtry u góry już działają i są zapisane w adresie strony, więc link odtwarza ten sam widok.
        </p>
      </div>
    </>
  );
}
