# Etap 6: specyfikacja (F2 Produkty, F3 Klienci, F6 Plan vs wykonanie)

Wersja 1.1, 2026-11-10 (1.1: reguła „Nowi”; wspólna lista odświeżania widoków w migracji integracyjnej). Ten dokument jest **kontraktem dla trzech równoległych sesji**: każda buduje jeden widok, opierając się na tym, co tu ustalono. Wymagania biznesowe: [requirements.md](requirements.md) (F2, F3, F6). Wzorzec techniczny: Etap 5 (F1 KPI).

---

## 0. Wspólne zasady (wszystkie trzy sesje)

### Wzorzec (jak F1)
- Agregaty liczone **w bazie**. Widoki zmaterializowane tylko w schemacie `analytics` (nie wystawionym przez API; widoki zmaterializowane ignorują RLS). Test `001_rls.test.sql` blokuje każdy widok zmaterializowany w `public`.
- Dane wychodzą wyłącznie przez funkcje `public.*` z `security definer`, `set search_path = ''`, `stable`, które **najpierw** wołają `private.assert_org_member(p_org_id)` i filtrują po `org_id`. `revoke ... from public, anon`, `grant execute ... to authenticated`.
- Nowe widoki zmaterializowane dodaj do `private.refresh_analytics()` (`create or replace`, `refresh materialized view concurrently`, wymaga indeksu unikalnego). Uwaga na konflikt: tę funkcję zmieniają wszystkie trzy sesje; patrz „Podział plików”.
- Dzień zamówienia = `(ordered_at at time zone 'Europe/Warsaw')::date`. Kwoty netto. Marża = `line_margin` (koszt z importu).
- Błędy po polsku: `22023` dla złych parametrów (np. `niepoprawny okres`), `42501` `brak dostępu do organizacji`.

### Parametry funkcji (ta sama kolejność co F1)
`p_org_id uuid, p_from date, p_to date, p_channel public.sales_channel default null, p_region_code text default null, p_category_code text default null`. Filtr, który w danym widoku nie ma sensu, **jest ignorowany, a UI mówi to wprost** (np. „Filtr kategorii nie dotyczy budżetów sklepów”).

### Aplikacja
- Strona `app/(app)/<widok>/page.tsx` w miejsce obecnego placeholdera; dane w `lib/data/<widok>.ts` (`server-only`, `getCurrentUser().orgId`, `getFilterContext`, `parseFilters`), czysta logika w `lib/<widok>.ts` z testami Vitest.
- Wszystko, co czyta sesję lub `searchParams`, w `<Suspense>` (Cache Components). Sprawdź `pnpm build`.
- Tabele: `components/data/data-table.tsx` (sortowanie, pusty stan). Linki w widoku: `FilterLink`. Formaty: `lib/format.ts`. Pusty wynik: `EmptyState` z konkretnym komunikatem.
- Wykresy: **przed pisaniem wykresu wczytaj skill `dataviz`**; kolory z tokenów `--viz-*` w `app/globals.css` (seria 1 niebieska); status (dobrze/źle) zawsze z ikoną i etykietą, nigdy samym kolorem; tooltip + widok tabeli.
- Limit API: maks. 1000 wierszy na zapytanie (patrz `getImportRun`). Lista produktów (~400) mieści się; większe wyniki stronicuj albo agreguj w SQL.

### Testy (warunek ukończenia)
1. **pgTAP** `supabase/tests/database/00N_<widok>.test.sql`: ręcznie policzony mały zestaw (wzorzec `005_kpi.test.sql`), filtry, przypadki brzegowe, dostęp (członek innej organizacji → `42501`, anon → `42501`). Stałe ID i daty poza zakresem prawdziwych danych (testy muszą przechodzić także na bazie z pełnymi danymi).
2. **Akceptacja na pełnych danych** `pipeline/tests/test_<widok>_db.py` (wzorzec `test_kpi_db.py`): funkcje vs kontrolne SQL na surowych tabelach + sprawdzenie zaszytych sygnałów z `_truth.json`. CI uruchamia automatycznie wszystkie `pipeline/tests/test_*_db.py`.
3. `pnpm lint && pnpm typecheck && pnpm test && pnpm build`, `supabase test db`, `scripts/check_calendar_parity.sh`.
4. Sprawdzenie w przeglądarce (komputer + telefon 375 px), czas strony < 2 s lokalnie.

### Podział plików (żeby sesje się nie blokowały)
| Sesja | Tylko te pliki / katalogi |
|---|---|
| F2 Produkty | migracja `*_products_analytics.sql`, `00N_products.test.sql`, `test_products_db.py`, `lib/products*.ts`, `lib/data/products.ts`, `components/products/`, `app/(app)/produkty/` |
| F3 Klienci | migracja `*_customers_analytics.sql`, `00N_customers.test.sql`, `test_customers_db.py`, `lib/customers*.ts`, `lib/data/customers.ts`, `components/customers/`, `app/(app)/klienci/` |
| F6 Plan | migracja `*_plan_analytics.sql`, `00N_plan.test.sql`, `test_plan_db.py`, `lib/plan*.ts`, `lib/data/plan.ts`, `components/plan/`, `app/(app)/plan/` |

- **Nie edytuj**: `CLAUDE.md`, `docs/*`, `.github/*`, `lib/filters.ts`, `lib/format.ts`, `components/data/*`, `components/ui/*`, `app/globals.css`, istniejących migracji. Potrzebna zmiana wspólnego pliku → opisz ją w PR, koordynator ją wprowadzi.
- `private.refresh_analytics()`: każda sesja ma w swojej migracji `create or replace` tej funkcji z **pełną** listą widoków (F1 + swoje). Przy scalaniu koordynator złoży wersję końcową w osobnej migracji. Numery testów pgTAP: F2 = `006`, F3 = `007`, F6 = `008`.
- Migracje: znacznik czasu z `supabase migration new` (różne sesje = różne znaczniki).

---

## 1. F2 Produkty

### Baza
- Widok zmaterializowany `analytics.sales_product_store_day` (`org_id, day, store_id, product_id, revenue, margin, units, orders`), indeks unikalny `(org_id, day, store_id, product_id)`. Jeśli pomiar pokaże, że zwykłe zapytanie na `order_lines` z indeksami mieści się w < 300 ms dla 2 lat, można zrezygnować z widoku i opisać pomiar w PR.
- `public.product_ranking(<parametry>)` → jeden wiersz na produkt ze sprzedażą w okresie:
  `sku, product_name, category_code, category_name, purchase_currency, revenue, margin, margin_pct, units, orders, revenue_share, cum_share, abc_class, rank`.
  - Kolejność ABC: `revenue desc, sku`. `cum_share` = skumulowany udział **łącznie z** produktem.
  - Klasa wg skumulowanego udziału **przed** produktem: `< 0,80` → A, `< 0,95` → B, reszta → C (pierwszy produkt zawsze A).
  - `margin_pct` = `margin / revenue` (null przy revenue 0).
- `public.product_abc_summary(<parametry>)` → `abc_class, products, revenue, revenue_share, product_share` (3 wiersze, sumy udziałów = 1).

### UI
- Kafelki A/B/C: liczba produktów, % produktów, % przychodu; progi opisane („A: pierwsze 80% przychodu”).
- Wykres Pareto: oś X = % produktów (posortowanych), oś Y = skumulowany % przychodu (linia), linie pomocnicze 80% i 95%.
- Tabela produktów: sortowanie po przychodzie, marży (zł i %), sztukach; kolumna klasy ABC i waluty zakupu (EUR = import).

### Akceptacja (requirements F2)
- Ranking sortuje się po każdej mierze i respektuje filtry (pgTAP + test na pełnych danych vs SQL).
- Suma udziałów klas = 100%; progi w UI.
- **Marża produktu importowanego**: test na pełnych danych dla 3 produktów EUR: `margin` funkcji = suma `quantity * (unit_price - unit_cost_pln)` z linii, a `unit_cost_pln` linii = średnia ważona z zakupów z 90 dni, z `unit_cost * kurs NBP` (data lub ostatni dzień publikacji przed).
- Pareto: top 20% SKU daje 70–85% przychodu dla pełnego okresu (sygnał z `_truth.json` → `pareto`).

---

## 2. F3 Klienci

Tylko klienci zidentyfikowani (`orders.customer_id is not null`); zakupy anonimowe w sklepach nie mają klienta. Filtr **kategorii jest ignorowany** (UI to mówi). Filtr **regionu = województwo klienta** (`customers.region_id`), filtr **kanału = kanał zamówienia**.

### RFM
- Data odniesienia = `p_to`. Okno = 365 dni do `p_to` włącznie. Klienci: ≥ 1 zamówienie z datą ≤ `p_to` (pasujące do filtrów).
- R = dni od ostatniego zamówienia do `p_to`; F = liczba zamówień w oknie; M = przychód w oknie.
- Oceny 1–5: `ntile(5)` po R rosnąco (najświeżsi = 5), po F i M malejąco (najwięcej = 5); remisy deterministycznie po `customer_code`. Klient bez zamówień w oknie: F = 0, M = 0 (dostaje najniższe oceny F i M).
- Segmenty (pierwsza pasująca reguła):
  1. **Mistrzowie**: R ≥ 4 i F ≥ 4
  2. **Lojalni**: F ≥ 4
  3. **Nowi**: R ≥ 4 i dokładnie 1 zamówienie w całej historii do `p_to` (świeży pierwszy zakup). *Poprawka 1.1: pierwotna reguła „F ≤ 1 jako ocena” była zawsze pusta, bo ocenę 1 dostają klienci bez zamówień w oknie; wykryła to sesja F3.*
  4. **Obiecujący**: R ≥ 3
  5. **Zagrożeni odejściem**: R = 2
  6. **Utraceni**: R = 1
- `public.customer_rfm_segments(<parametry>)` → `segment, customers, revenue, avg_recency_days, avg_frequency, share_customers, share_revenue` (zawsze 6 wierszy, kolejność jak wyżej).
- Opcjonalnie `public.customer_rfm_scores(...)` do rozkładu (≤ 1000 wierszy nie wolno zakładać: 20 tys. klientów → tylko agregaty).

### Kohorty
- Kohorta = miesiąc pierwszego zamówienia klienta (w całej historii, pasującego do filtrów kanału i regionu), tylko kohorty z pierwszym zamówieniem w `[p_from, p_to]`.
- `public.customer_cohorts(<parametry>)` → `cohort_month, months_since, cohort_size, active_customers, retention` dla `months_since` 0..(ostatni pełny miesiąc danych); miesiąc 0 = 100%.

### UI
- Tabela/kafelki segmentów: liczba klientów, przychód, udziały, krótki opis segmentu.
- Heatmapa kohort: wiersze = kohorty, kolumny = miesiące od pierwszego zakupu, kolor = sekwencyjny jeden odcień (skill `dataviz`), wartości % w komórkach lub w tooltipie + widok tabeli.

### Akceptacja (requirements F3)
- Każdy klient z ≥ 1 zakupem ma segment: suma `customers` po segmentach = liczba klientów (test vs SQL).
- Liczba klientów i przychód w segmentach zgodne z kontrolnym SQL.
- Heatmapa: miesiąc 0 = 100%.
- Sygnał churnu z generatora widoczny: retencja spada z kolejnymi miesiącami, kohorty promocyjne (`_truth.json` → `churn.promo_cohort_rule`) mają niższą retencję po 6 miesiącach niż pozostałe, segment „Utraceni” niepusty dla pełnego okresu.

---

## 3. F6 Plan vs wykonanie

Budżet jest per sklep × miesiąc, więc filtr **kategorii jest ignorowany** (UI to mówi). Kanał i region filtrują sklepy.

### Baza
- Wykonanie z `analytics.sales_store_day` (już istnieje, F1), zsumowane do miesięcy. Bez nowych widoków zmaterializowanych (chyba że pomiar pokaże potrzebę).
- Miesiące: tylko **pełne miesiące** całkowicie w `[p_from, p_to]` (porównanie części miesiąca z pełnym planem byłoby mylące). Brak pełnego miesiąca → pusty wynik, UI: „Wybierz okres obejmujący co najmniej jeden pełny miesiąc”.
- `public.plan_vs_actual(<parametry>)` → wiersze na trzech poziomach (`grouping sets`):
  `level ('store' | 'region' | 'network'), store_code, store_name, region_code, region_name, month (null dla sum okresu), plan, actual, realization, deviation`.
  - `realization = actual / plan` (null przy plan 0); `deviation = actual - plan`.
  - Sklep internetowy: region null, w poziomie `region` jako osobna grupa „Sklep internetowy”.

### UI
- Podsumowanie: sieć (kafelek), regiony (tabela), sklepy (tabela).
- Tabela sklep × miesiąc z % realizacji; kolorowanie wg wymagań: < 90% czerwony, 90–100% żółty, ≥ 100% zielony, **z ikoną/etykietą** (status nie może być samym kolorem), legenda progów.

### Akceptacja (requirements F6)
- Każdy sklep ma budżet na każdy pełny miesiąc z zakresu (test na pełnych danych).
- % realizacji = wykonanie / plan × 100, zgodne z kontrolnym SQL (sieć, region, sklep).
- Słabe sklepy z `_truth.json` (`weak_stores`: KAT-01, WAW-02, OLS-01, oczekiwana realizacja ~78%) mają realizację < 90% za pełne 2 lata; pozostałe sklepy (poza `declining_stores`) 90–105%.

---

## 4. Ukończenie każdej sesji

PR do `main` z: planem, opisem decyzji (zwłaszcza gdzie specyfikacja wymagała interpretacji), wynikami testów i pomiarem czasu. Bez scalania: koordynator robi review, test integracji wszystkich trzech gałęzi razem (konflikty w `refresh_analytics`, numerach testów), scala i wypycha migracje na produkcję.
