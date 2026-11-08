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

## Etap 2: Model danych i generator ✅

- [x] Kontrakt danych: [data-model.md](data-model.md) (v1.1: kwoty netto): #6, #10
- [x] ⫽ Schemat bazy: wymiary, fakty, `fx_rates`, `calendar` 2022–2030, RLS z szybkimi politykami (~50 ms na 445 tys. pozycji jako demo), blokada przenoszenia wierszy między organizacjami, 205 testów pgTAP: #8
- [x] ⫽ Generator + kursy NBP: deterministyczny, ~2 s, ~199 tys. zamówień / ~446 tys. pozycji, 10 zaszytych sygnałów zmierzonych testami, 69 testów: #9
- [x] Test integracji: wszystkie czyste wiersze ładują się do schematu (157 MB), kalendarze Python i SQL identyczne (kontrola w CI)

## Etap 3: Pipeline importu ✅

- [x] Staging → walidacja (błędy po polsku) → model → log importu, logika w `private.process_import` (SQL)
- [x] Kurs NBP dla zakupów w EUR, koszt pozycji = średnia ważona zakupów z 90 dni
- [x] Idempotentność: ponowny import tych samych plików nie zmienia ani jednego wiersza
- [x] Komenda `datarift-pipeline import`: pełne dane (~695 tys. wierszy) w ~16 s lokalnie
- [x] Testy: 37 przypadków pgTAP dla reguł walidacji, pełny import w CI porównany z `_truth.json`
- [x] Import pełnych danych demo na produkcję: 693 647 wierszy, 1 287 zaplanowanych błędów, ~2 min, 199 MB z 500 MB
- Widoki materializowane przeniesione do Etapu 5 (powstaną razem z dashboardem KPI)

## Etap 4: Logowanie i szkielet aplikacji ✅

- [x] „Zobacz demo” loguje jednym kliknięciem na konto `demo` (hasło tylko na serwerze); logowanie admina e-mail + hasło; wylogowanie
- [x] Ochrona widoków: `proxy.ts` (szybkie przekierowanie) + sprawdzenie użytkownika w każdym widoku (`lib/auth.ts`)
- [x] Layout: boczne menu, wersja mobilna (od 360 px) z wysuwanym menu i panelem filtrów, baner trybu demo
- [x] Filtry globalne (okres, kanał, region, kategoria) zapisane w URL, przenoszone między widokami, 14 testów
- [x] Wspólne komponenty: tabela z sortowaniem, pusty stan, ładowanie, błąd
- [x] Pierwszy widok z danymi: lista importów i szczegóły z błędami walidacji (część F4)
- [x] Produkcja: konto demo i admina (role nadane w bazie), zmienne środowiskowe w Vercel, Site URL i limit logowań w Supabase; demo sprawdzone na https://datarift-demo.vercel.app
- [x] Funkcje Vercel we Frankfurcie (`fra1`, `vercel.json`), obok bazy (wcześniej `iad1`: każde zapytanie przez Atlantyk)

## Etap 5: F1 Dashboard KPI ✅

- [x] Widoki zmaterializowane (dzień × sklep, dzień × sklep × kategoria) w schemacie `analytics`, odświeżane `CONCURRENTLY` po imporcie; dostęp tylko przez funkcje sprawdzające członkostwo
- [x] `kpi_summary` (okres + poprzedni okres tej samej długości) i `kpi_timeseries` (dzień/tydzień/miesiąc, puste okresy = 0)
- [x] 4 kafelki KPI ze zmianą (strzałka, znak, kolor, nazwany okres), marża w zł i % (zmiana w p.p.), „brak danych do porównania” zamiast mylącego +100%
- [x] Wykres przychodu: niepełne okresy na brzegach jaśniejsze, tooltip, tabela z danymi
- [x] Testy zgodności: 22 przypadki pgTAP + funkcje vs kontrolne SQL na pełnych danych (6 kombinacji filtrów) w CI
- [x] Produkcja: migracja wypchnięta, wartości zgodne z kontrolnym SQL; `/kpi` 0,35–0,68 s po rozgrzaniu (1,9 s przy zimnym starcie po wdrożeniu)

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
