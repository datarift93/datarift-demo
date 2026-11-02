# datarift-demo: wymagania

Wersja: 0.1 (szkic), 2026-11-02

---

## 1. Cel i odbiorca demo

### Cel
Aplikacja portfolio, która na realistycznych danych pokazuje pełny proces BI: od wygenerowania i zaimportowania danych, przez ich walidację i modelowanie, po interaktywne dashboardy i automatyczne wnioski. Demo ma przekonać potencjalnego klienta, że autor potrafi dostarczyć działające rozwiązanie analityczne od początku do końca, a nie tylko pojedynczy raport.

### Scenariusz
Analiza sprzedaży fikcyjnej polskiej sieci handlowej **„Wisła”**:
- ok. **25 sklepów stacjonarnych** w różnych województwach,
- **sklep internetowy** jako osobny kanał,
- dane z **2 pełnych lat**.

### Odbiorca
- **Właściciele i managerowie małych i średnich firm** (handel, e-commerce), którzy szukają wykonawcy BI/analityki danych.
- **Decydenci nietechniczni**: chcą w 2–3 minuty zobaczyć konkretne odpowiedzi biznesowe („który sklep słabnie?”, „które produkty zarabiają?”).
- **Osoby techniczne po stronie klienta** (IT, analitycy): oceniają jakość pipeline’u, modelu danych i bezpieczeństwa.

### Kryteria sukcesu demo
- Odbiorca wchodzi na stronę i jednym kliknięciem ogląda dane, bez rejestracji.
- W ciągu kilku minut widzi przynajmniej 3 nieoczywiste wnioski (np. spadek w konkretnym sklepie, efekt Black Friday, odpływ klientów).
- Kod i dokumentacja w repozytorium pokazują dobre praktyki (migracje, RLS, testy, CI).

---

## 2. Dane

### 2.1 Generowanie
- Dane generuje **skrypt Python** (`pipeline/`), deterministycznie (stały `seed`), więc każde uruchomienie daje ten sam wynik.
- Parametry generatora (liczba sklepów, zakres dat, liczba klientów, seed) w pliku konfiguracyjnym.
- Skala docelowa: **kilkaset tysięcy wierszy** łącznie (orientacyjnie 300–600 tys. pozycji zamówień).

### 2.2 Realizm danych
Generator musi uwzględniać:
- **Sezonowość**: roczną (grudzień i okres przedświąteczny, wakacje, słabszy styczeń–luty) i tygodniową (weekendy w sklepach stacjonarnych, inne wzorce w kanale online).
- **Promocje**: okresowe obniżki cen wybranych kategorii i produktów, z widocznym wzrostem wolumenu i spadkiem marży.
- **Black Friday**: wyraźny skok sprzedaży (szczególnie online) w ostatni piątek listopada i w Cyber Monday.
- **Słabsze sklepy**: część sklepów ma trwale niższe wyniki, a 1–2 sklepy mają wyraźny spadek w określonym okresie (np. nowa konkurencja), który powinien wykryć moduł anomalii (F7).
- **Odpływ klientów (churn)**: klienci mają cykl życia; część przestaje kupować, a kohorty różnią się retencją.
- **Zróżnicowanie regionalne**: różna wielkość sklepów i siła nabywcza w województwach.
- **Struktura asortymentu**: kilka kategorii o różnej marżowości; rozkład sprzedaży zbliżony do Pareto (podstawa analizy ABC).

### 2.3 Prawdziwe źródło: kursy walut NBP
- Część towaru sieć kupuje od dostawców zagranicznych w **EUR**.
- Koszt zakupu w PLN przeliczany jest po **rzeczywistym kursie średnim EUR/PLN z API NBP** (tabela A) z dnia transakcji zakupu (lub ostatniego dnia roboczego przed nim).
- Kursy pobierane skryptem Python i zapisywane w bazie (tabela kursów), żeby nie odpytywać API przy każdym przeliczeniu.
- Wahania kursu przekładają się na marżę produktów importowanych.

### 2.4 Pipeline importu
Każdy import przechodzi przez etapy:

1. **Staging**: surowe dane ładowane do tabel `staging` bez transformacji.
2. **Walidacja**: kontrola m.in. typów, wartości wymaganych, kluczy obcych (np. istniejący sklep i produkt), zakresów (ilość > 0, cena ≥ 0), duplikatów i spójności dat. Wiersze błędne odrzucane z opisem błędu.
3. **Model docelowy**: poprawne dane trafiają do modelu analitycznego (wymiary: sklep, region, kanał, produkt, kategoria, klient, data; fakty: sprzedaż, zakupy, budżet).
4. **Log importu**: każde uruchomienie zapisuje identyfikator, czas startu i końca, status (`running` / `success` / `partial` / `failed`), liczbę wierszy wczytanych, poprawnych i odrzuconych oraz listę błędów.

Import musi być **idempotentny**: ponowne uruchomienie dla tych samych danych nie tworzy duplikatów.

---

## 3. Użytkownicy i role

| Rola    | Uprawnienia                                                                 | Logowanie                               |
|---------|-----------------------------------------------------------------------------|-----------------------------------------|
| `admin` | Pełny dostęp do danych swojej organizacji, uruchamianie i podgląd importów   | E-mail + hasło (Supabase Auth)          |
| `demo`  | Tylko odczyt danych organizacji demo; brak uruchamiania importów, brak zapisu | **Jednym kliknięciem** („Zobacz demo”)  |

### Wielodostępność (multi-tenant)
- Wszystkie dane biznesowe mają kolumnę **`org_id`**.
- Dostęp wymusza **Row Level Security** w Postgres: użytkownik widzi wyłącznie wiersze swojej organizacji.
- Rola użytkownika i przynależność do organizacji zapisane w tabeli członkostwa (np. `org_members`).
- Konto demo nie może zmienić danych, nawet przy bezpośrednim wywołaniu API (wymuszone przez RLS, nie tylko przez UI).

---

## 4. Funkcje MVP

Wszystkie widoki analityczne (F1–F3, F6, F7) respektują filtry globalne tam, gdzie mają sens: **okres, kanał, region, kategoria**.

### F1. Dashboard KPI
Ekran główny z kluczowymi wskaźnikami.

**Zakres:**
- KPI: **przychód**, **marża** (kwotowo i %), **liczba zamówień**, **średni koszyk**.
- Przy każdym KPI **zmiana vs poprzedni okres** tej samej długości (kwotowo/%, ze strzałką i kolorem).
- Wykres przychodu w czasie (dzień/tydzień/miesiąc zależnie od zakresu).
- Filtry: **okres**, **kanał** (stacjonarny / online), **region** (województwo), **kategoria**.

**Kryteria akceptacji:**
- [ ] Wszystkie 4 KPI wyświetlają się z wartością i zmianą vs poprzedni okres.
- [ ] Zmiana filtra aktualizuje KPI i wykres; wartości zgadzają się z kontrolnym zapytaniem SQL na danych źródłowych.
- [ ] Filtry można łączyć (np. online + kategoria X + ostatni kwartał).
- [ ] Stan filtrów jest w URL, więc link odtwarza ten sam widok.
- [ ] Brak danych dla wybranych filtrów pokazuje czytelny komunikat zamiast pustego wykresu lub błędu.

### F2. Produkty
**Zakres:**
- Ranking produktów według przychodu, marży i liczby sztuk (sortowanie).
- **Analiza ABC**: klasyfikacja produktów wg udziału w przychodzie (A ≈ 80%, B ≈ 15%, C ≈ 5%), z podsumowaniem liczby produktów i udziału w każdej klasie.
- **Marża na produkcie**: kwotowa i procentowa, z uwzględnieniem kosztu zakupu (także przeliczonego z EUR).

**Kryteria akceptacji:**
- [ ] Ranking sortuje się po każdej z miar i respektuje filtry globalne.
- [ ] Suma udziałów klas ABC = 100%; progi klas są opisane w UI.
- [ ] Marża produktu importowanego zgadza się z ręcznym przeliczeniem po kursie NBP z dnia zakupu.
- [ ] Wykres Pareto (skumulowany udział) dla analizy ABC.

### F3. Klienci
**Zakres:**
- **Segmentacja RFM** (Recency, Frequency, Monetary): ocena 1–5 w każdym wymiarze i nazwane segmenty (np. „Lojalni”, „Zagrożeni odejściem”, „Utraceni”, „Nowi”).
- **Kohorty retencji**: macierz kohort miesięcznych (miesiąc pierwszego zakupu × kolejne miesiące), % klientów, którzy wrócili.

**Kryteria akceptacji:**
- [ ] Każdy klient z co najmniej jednym zakupem ma przypisany segment RFM.
- [ ] Widok pokazuje liczbę klientów i przychód w każdym segmencie.
- [ ] Macierz kohort pokazuje % retencji jako heatmapę; miesiąc 0 = 100%.
- [ ] Odpływ klientów zaszyty w generatorze jest widoczny w danych (spadająca retencja, segment „Utraceni”).

### F4. Importy
**Zakres:**
- Historia uruchomień pipeline’u: data, czas trwania, status, liczba wierszy (wczytane / poprawne / odrzucone).
- Szczegóły importu: lista błędów walidacji (wiersz, pole, opis).
- Uruchomienie importu z UI (tylko `admin`); `demo` widzi historię w trybie tylko do odczytu.

**Kryteria akceptacji:**
- [ ] Każde uruchomienie pipeline’u pojawia się na liście ze statusem.
- [ ] Liczby wierszy zgadzają się z logiem importu w bazie.
- [ ] Szczegóły pokazują błędy walidacji z opisem po polsku.
- [ ] Użytkownik `demo` nie widzi akcji uruchomienia, a wywołanie API przez `demo` zwraca błąd uprawnień.

### F5. Eksport do CSV
**Zakres:**
- Każda tabela w aplikacji ma przycisk **„Eksportuj CSV”**.

**Kryteria akceptacji:**
- [ ] Eksport zawiera dane zgodne z aktualnymi filtrami i sortowaniem.
- [ ] Plik otwiera się poprawnie w Excelu z polskimi znakami (UTF-8 z BOM, separator `;`, przecinek dziesiętny).
- [ ] Nazwa pliku zawiera nazwę widoku i datę (np. `produkty_2026-11-02.csv`).
- [ ] Eksport działa także dla roli `demo`.

### F6. Plan vs wykonanie
**Zakres:**
- Budżet sprzedaży (plan) dla każdego **sklepu i miesiąca**, generowany razem z danymi.
- Porównanie planu z wykonaniem: kwota planu, kwota wykonania, **% realizacji**, odchylenie.
- Widok tabeli sklep × miesiąc z kolorowaniem (np. < 90% czerwony, 90–100% żółty, ≥ 100% zielony).

**Kryteria akceptacji:**
- [ ] Każdy sklep ma budżet na każdy miesiąc z zakresu danych.
- [ ] % realizacji = wykonanie / plan × 100, zgodne z kontrolnym zapytaniem SQL.
- [ ] Można zobaczyć podsumowanie dla całej sieci, regionu i pojedynczego sklepu.
- [ ] Sklepy słabsze (z generatora) wyraźnie odstają w realizacji planu.

### F7. Anomalie
**Zakres:**
- Automatyczne wykrywanie odchyleń, np.:
  - spadek sprzedaży sklepu **tydzień do tygodnia** powyżej progu (np. > 20% przy porównaniu z tym samym tygodniem rok wcześniej lub średnią kroczącą, żeby nie zgłaszać sezonowości),
  - nietypowy spadek marży w kategorii,
  - nagły wzrost lub spadek liczby zamówień online.
- **Lista alertów**: data, obiekt (sklep / kategoria / kanał), typ, wielkość odchylenia i **opis tekstowy po polsku** (np. „Sklep Kraków 2: sprzedaż w tygodniu 12–18.05 niższa o 34% niż średnia z 4 poprzednich tygodni”).

**Kryteria akceptacji:**
- [ ] Spadek sprzedaży zaszyty w generatorze dla wybranego sklepu zostaje wykryty i pokazany jako alert.
- [ ] Black Friday i grudniowe szczyty nie generują fałszywych alertów spadku.
- [ ] Każdy alert ma czytelny opis i link do odpowiedniego widoku z ustawionymi filtrami.
- [ ] Progi wykrywania są konfigurowalne (w bazie lub konfiguracji), a nie zaszyte w UI.

---

## 5. Wymagania niefunkcjonalne

### Język i formaty
- Cały interfejs **po polsku**.
- Kwoty w **zł**, format polski: `1 234 567,89 zł`; daty `DD.MM.RRRR`; procenty z przecinkiem.

### Responsywność
- Aplikacja **działa na telefonie** (od szerokości 360 px): KPI w układzie kolumnowym, tabele z przewijaniem poziomym lub uproszczonym widokiem, filtry w wysuwanym panelu.

### Wydajność
- Każda strona ładuje się w **< 2 s** (dane z produkcji Vercel + Supabase, typowe łącze).
- **Agregaty liczone w bazie**: widoki i widoki materializowane w Postgres, a nie agregacja w przeglądarce ani w Node.
- Widoki materializowane odświeżane po każdym udanym imporcie.
- Indeksy na kolumnach używanych w filtrach (`org_id`, data, sklep, kanał, kategoria).

### Koszty i limity
- Całość mieści się w **darmowym planie Supabase** (m.in. limit rozmiaru bazy ~500 MB) i darmowym planie Vercel.
- Rozmiar danych i indeksów monitorowany; generator ma parametr skali, żeby zejść poniżej limitu.

### Bezpieczeństwo
- RLS włączone na każdej tabeli; brak tabel dostępnych bez polityk.
- Klucze i sekrety wyłącznie w zmiennych środowiskowych; klucz `service_role` nigdy nie trafia do przeglądarki.

### Jakość
- TypeScript w trybie `strict`.
- Testy jednostkowe logiki (obliczenia KPI, RFM, ABC, walidacja w pipeline) i testy polityk RLS.
- CI w GitHub Actions: lint, typecheck, testy przy każdym PR.

---

## 6. Poza zakresem MVP

- Rejestracja nowych użytkowników i organizacji (konta zakłada admin).
- Upload własnych danych klienta (→ R2).
- Prognozowanie sprzedaży (→ R1).
- Zapytania w języku naturalnym (→ R3).
- Edycja budżetu w UI (budżet pochodzi z generatora/importu).
- Powiadomienia o alertach (e-mail, Slack, push).
- Wielojęzyczność UI i inne waluty prezentacji niż PLN.
- Dane w czasie rzeczywistym / streaming; integracje z prawdziwymi systemami (ERP, POS).
- Dashboardy konfigurowane przez użytkownika (drag & drop).
- Zaawansowane uprawnienia (np. dostęp tylko do wybranych sklepów lub regionów).

---

## 7. Roadmapa po MVP

### R1. Prognoza sprzedaży (Python)
- Model prognozy (np. Prophet / statsmodels) na poziomie sieci, sklepu i kategorii, z uwzględnieniem sezonowości i promocji.
- Prognoza na kolejne 1–3 miesiące z przedziałami ufności, zapisywana w bazie i pokazywana na wykresach obok danych historycznych oraz planu (F6).

### R2. Upload własnego CSV klienta
- Klient wgrywa własny plik CSV, mapuje kolumny na model danych i przechodzi przez ten sam pipeline (staging → walidacja → model → log).
- Dane w osobnej organizacji (`org_id`), izolowane przez RLS, z limitem rozmiaru i automatycznym usuwaniem po czasie.

### R3. Czat z danymi (tekst → SQL)
- Pytanie po polsku („Który sklep na Mazowszu miał największy spadek w październiku?”) zamieniane przez LLM na zapytanie SQL.
- Zapytania wykonywane wyłącznie w trybie tylko do odczytu, na whiteliście widoków, z RLS i limitem czasu.
- Odpowiedź pokazuje wynik, użyte zapytanie SQL i, jeśli ma to sens, wykres.
