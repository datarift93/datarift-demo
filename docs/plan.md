# datarift-demo: plan etapów

Kolejność budowy MVP z [requirements.md](requirements.md). Każdy etap kończy się działającym, przetestowanym kodem na `main` (przez PR-y). Odhaczaj kryteria w PR, który je spełnia.

**Legenda:** ✅ zrobione · 🔄 w toku · ⏳ do zrobienia · ⫽ można robić równolegle (osobne sesje / worktree)

---

## Etap 1: Szkielet ✅

- [x] Next.js 16, TypeScript strict, Tailwind, shadcn/ui, polskie formaty (`lib/format.ts`): #1
- [x] Supabase: `orgs`, `org_members`, role `admin`/`demo`, RLS, testy pgTAP: #2
- [x] Pipeline Python: uv, walidowana konfiguracja generatora: #3
- [x] CI: web, baza, pipeline
- [x] Workflow: hooki (lint po edycji, blokada commitów na `main`), ochrona `main` na GitHubie, ten plan
- [x] Wczesny deploy: Vercel (https://datarift-demo.vercel.app), Supabase we Frankfurcie, migracje na produkcji, RLS sprawdzone

## Etap 2: Model danych i generator ⏳

Najpierw **kontrakt danych** (tabele, kolumny, typy, klucze) w `docs/data-model.md`. Potem dwie niezależne ścieżki:

- ⫽ **Schemat bazy**: migracje wymiarów (sklep, region, kanał, produkt, kategoria, klient, data) i faktów (sprzedaż, zakupy, budżet), tabela kursów NBP, `org_id` + RLS + testy, indeksy pod filtry
- ⫽ **Generator**: deterministyczny (seed), realizm z sekcji 2.2 (sezonowość, promocje, Black Friday, słabe i spadające sklepy, churn, regiony, Pareto), budżet sklep × miesiąc; testy, że wzorce są w danych
- ⫽ **Kursy NBP**: pobieranie EUR/PLN (tabela A), ostatni dzień roboczy, zapis do bazy, testy z nagranymi odpowiedziami API

Kryterium: wygenerowane dane mieszczą się w limicie darmowego Supabase.

## Etap 3: Pipeline importu ⏳

- [ ] Staging → walidacja (błędy po polsku) → model → log importu
- [ ] Idempotentność (ponowny import bez duplikatów)
- [ ] Odświeżanie widoków materializowanych po udanym imporcie
- [ ] Import pełnych danych demo do lokalnej bazy i na produkcję

## Etap 4: Logowanie i szkielet aplikacji ⏳

- [ ] „Zobacz demo” loguje jednym kliknięciem na konto `demo`; logowanie admina e-mail + hasło
- [ ] Produkcja: zmienne środowiskowe Supabase w Vercel, konto demo i organizacja na produkcji, Site URL w ustawieniach auth
- [ ] Layout: nawigacja między widokami, wersja mobilna (od 360 px)
- [ ] Filtry globalne (okres, kanał, region, kategoria) zapisane w URL
- [ ] Wspólne komponenty: tabela z sortowaniem, pusty stan, ładowanie, błędy

## Etap 5: F1 Dashboard KPI ⏳

- [ ] Widoki SQL dla KPI i zmiany vs poprzedni okres
- [ ] Wykres przychodu w czasie (dzień/tydzień/miesiąc)
- [ ] Testy zgodności z kontrolnym zapytaniem SQL

## Etap 6: Analizy ⏳

- ⫽ **F2 Produkty**: ranking, ABC, Pareto, marża z kursem NBP
- ⫽ **F3 Klienci**: RFM, kohorty retencji (heatmapa)
- ⫽ **F6 Plan vs wykonanie**: tabela sklep × miesiąc z kolorami, podsumowania sieć/region/sklep

## Etap 7: F7 Anomalie ⏳

- [ ] Wykrywanie spadków sklepu (vs średnia krocząca / rok wcześniej), marży kategorii, zamówień online
- [ ] Progi w bazie, opisy po polsku, linki do widoków z filtrami
- [ ] Testy: wykrywa spadek z generatora, nie zgłasza Black Friday i grudnia

## Etap 8: Importy i eksport ⏳

- ⫽ **F4 Importy**: historia, szczegóły błędów, uruchomienie tylko dla `admin`
- ⫽ **F5 Eksport CSV**: UTF-8 z BOM, `;`, przecinek dziesiętny, nazwa z datą, działa dla `demo`

## Etap 9: Szlify przed pokazaniem klientom ⏳

- [ ] Wydajność: każda strona < 2 s na produkcji
- [ ] Testy end-to-end kluczowych ścieżek (Playwright)
- [ ] README jako wizytówka: zrzuty ekranu, architektura, jak uruchomić
- [ ] Przegląd bezpieczeństwa (RLS, klucze, uprawnienia `demo`)

## Po MVP

R1 prognoza sprzedaży · R2 upload własnego CSV · R3 czat z danymi (tekst → SQL). Szczegóły w [requirements.md](requirements.md#7-roadmapa-po-mvp).
