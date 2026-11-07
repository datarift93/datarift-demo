import { Button } from "@/components/ui/button";

const features = [
  { title: "KPI", text: "Przychód, marża, zamówienia i średni koszyk z porównaniem do poprzedniego okresu." },
  { title: "Produkty", text: "Ranking, analiza ABC i marża z kosztem zakupu przeliczonym po kursie NBP." },
  { title: "Klienci", text: "Segmentacja RFM i kohorty retencji." },
  { title: "Plan vs wykonanie", text: "Realizacja budżetu dla każdego sklepu i miesiąca." },
  { title: "Anomalie", text: "Automatyczne alerty o nietypowych spadkach sprzedaży i marży." },
  { title: "Importy", text: "Pipeline z walidacją danych i pełnym logiem importu." },
];

export default function Home() {
  return (
    <main className="mx-auto flex w-full max-w-4xl flex-1 flex-col gap-12 px-4 py-16 sm:px-8 sm:py-24">
      <section className="flex flex-col gap-6">
        <p className="text-sm font-medium text-muted-foreground">datarift · demo BI</p>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-5xl">
          Analityka sprzedaży sieci „Wisła”
        </h1>
        <p className="max-w-2xl text-lg text-muted-foreground">
          25 sklepów stacjonarnych i sklep internetowy, dwa lata danych. Zobacz, jak wygląda
          kompletne rozwiązanie BI: od importu i walidacji danych po dashboardy i automatyczne
          wnioski.
        </p>
        <div>
          {/* Wired to the one-click demo login in a later stage. */}
          <Button size="lg" disabled>
            Zobacz demo (wkrótce)
          </Button>
        </div>
      </section>

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {features.map((f) => (
          <div key={f.title} className="rounded-lg border p-4">
            <h2 className="font-medium">{f.title}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{f.text}</p>
          </div>
        ))}
      </section>
    </main>
  );
}
