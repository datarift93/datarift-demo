# datarift-demo: kontrakt danych

Wersja: 1.0 (zaakceptowana), 2026-11-07

Ten dokument jest **umową między generatorem (Python) a bazą (Supabase)**. Obie strony implementują dokładnie to, co tu opisano, i mogą powstawać równolegle. Zmiana kontraktu = PR zmieniający ten plik, zanim zmieni się kod.

Identyfikatory (tabele, kolumny, pliki) po angielsku, opisy po polsku.

---

## 1. Przepływ

```
NBP API ──> pipeline/data/fx_eur_pln.csv   (pobrane raz, w repo: dane deterministyczne)
                       │
config/generator.toml ─┴─> generator ──> pipeline/out/*.csv + _truth.json
                                              │
                                    (Etap 3) import: staging → walidacja → model → log
```

- Generator czyta kursy z pliku w repo, a nie z API. Ten sam seed daje te same dane także za rok.
- `pipeline/out/` jest w `.gitignore`. Dane generuje się lokalnie i w CI.
- `_truth.json` opisuje **zaszyte sygnały** (np. który sklep i od kiedy słabnie). Testy generatora i później F7 sprawdzają, czy te sygnały są w danych i czy anomalie je wykrywają.

## 2. Pliki CSV (wyjście generatora = wejście importu)

Format wspólny: UTF-8 bez BOM, separator `,`, nagłówek w pierwszym wierszu, kropka dziesiętna, daty `YYYY-MM-DD`, znaczniki czasu ISO 8601 z czasem lokalnym Polski (`2025-11-28T14:05:00+01:00`), puste pole = `NULL`. Kwoty w PLN z 2 miejscami po przecinku.

`org_id` **nie** występuje w plikach. Nadaje go import (organizacja docelowa jest parametrem importu). Klucze w plikach to **kody biznesowe** (`store_code`, `sku`…), nie identyfikatory z bazy.

### regions.csv (16 województw)
| kolumna | typ | opis |
|---|---|---|
| region_code | text, PK | kod TERYT województwa, np. `14` |
| name | text | np. `mazowieckie` |
| purchasing_power_index | decimal | 1.00 = średnia krajowa |

### stores.csv (25 stacjonarnych + 1 online)
| kolumna | typ | opis |
|---|---|---|
| store_code | text, PK | np. `KRK-02`, online: `ONLINE` |
| name | text | np. `Kraków 2`, `Sklep internetowy` |
| channel | `store` / `online` | |
| city | text | pusty dla online |
| region_code | text → regions | pusty dla online |
| size_m2 | int | pusty dla online |
| opened_on | date | |

### categories.csv (6–8 kategorii)
| kolumna | typ | opis |
|---|---|---|
| category_code | text, PK | np. `HOME` |
| name | text | np. `Dom i ogród` |

### products.csv (~400 produktów)
| kolumna | typ | opis |
|---|---|---|
| sku | text, PK | np. `HOME-0042` |
| name | text | |
| category_code | text → categories | |
| list_price | decimal PLN | cena katalogowa brutto |
| purchase_currency | `PLN` / `EUR` | ~30% produktów importowanych |

### customers.csv
| kolumna | typ | opis |
|---|---|---|
| customer_code | text, PK | np. `C000123` |
| region_code | text → regions | |
| registered_on | date | założenie karty / konta |

### promotions.csv
| kolumna | typ | opis |
|---|---|---|
| promo_code | text, PK | np. `BF-2025` |
| name | text | np. `Black Friday 2025` |
| starts_on, ends_on | date | włącznie |
| category_code | text, NULL | NULL i `sku` NULL = cały asortyment |
| sku | text, NULL | |
| discount_pct | decimal 0–1 | |

### purchases.csv (zakupy towaru od dostawców)
| kolumna | typ | opis |
|---|---|---|
| purchase_code | text, PK | |
| sku | text → products | |
| purchase_date | date | |
| quantity | int > 0 | |
| unit_cost | decimal | w walucie zakupu |
| currency | `PLN` / `EUR` | |

Przeliczenie na PLN (`fx_rate`, `unit_cost_pln`) robi **import**, a nie generator: kurs NBP z dnia zakupu lub ostatniego dnia roboczego przed nim. Dzięki temu logika z wymagań (2.3) jest w bazie i da się ją przetestować.

### orders.csv (~200 tys.)
| kolumna | typ | opis |
|---|---|---|
| order_code | text, PK | |
| store_code | text → stores | kanał wynika ze sklepu |
| customer_code | text, NULL | NULL = zakup anonimowy w sklepie (bez karty) |
| ordered_at | timestamptz | |

### order_lines.csv (300–600 tys.)
| kolumna | typ | opis |
|---|---|---|
| order_code | text → orders | |
| line_no | int | PK razem z `order_code` |
| sku | text → products | |
| quantity | int > 0 | |
| unit_price | decimal PLN | cena po rabacie |
| promo_code | text, NULL | promocja, która obniżyła cenę |

### budgets.csv (sklep × miesiąc)
| kolumna | typ | opis |
|---|---|---|
| store_code | text → stores | |
| month | date | pierwszy dzień miesiąca |
| revenue_plan | decimal PLN | |

### fx_eur_pln.csv (w repo, `pipeline/data/`)
| kolumna | typ | opis |
|---|---|---|
| rate_date | date, PK | tylko dni publikacji NBP |
| mid_rate | decimal(10,4) | kurs średni, tabela A |
| table_no | text | np. `214/A/NBP/2025` |

### Celowo błędne wiersze
Generator dokłada ułamek błędnych wierszy (parametr `dirty_row_rate`, domyślnie 0,2%): nieistniejący SKU, ilość 0, ujemna cena, duplikat, data spoza zakresu. Bez nich F4 (lista błędów importu) nie miałby czego pokazać. Każdy błędny wiersz jest zapisany w `_truth.json`, więc testy importu sprawdzą, że odrzucono dokładnie te wiersze.

## 3. Model w bazie

Wszystkie tabele w `public` mają `org_id`, RLS i polityki z `private.is_org_member` / `private.is_org_admin`. Klucze techniczne to `bigint generated always as identity`, a kody biznesowe są unikalne w ramach `org_id`. Kwoty: `numeric(12,2)`.

**Wymiary:** `regions`, `stores`, `categories`, `products`, `customers`, `promotions`
**Fakty:** `orders`, `order_lines`, `purchases`, `budgets`
**Referencyjne (globalne, bez `org_id`):** `fx_rates` (kursy NBP to dane publiczne, wspólne dla wszystkich), `calendar` (dni z flagami: dzień tygodnia, święto w Polsce, Black Friday, Cyber Monday). Tylko odczyt dla `authenticated`, zapis tylko przez import.

Kolumny liczone przy imporcie (żeby agregaty w bazie były proste i szybkie):
- `purchases.fx_rate`, `purchases.unit_cost_pln`
- `order_lines.unit_cost_pln`: średni ważony koszt zakupu produktu z ostatnich 90 dni przed datą zamówienia. Z niego liczy się marżę w F1, F2 i F7.
- `order_lines.line_revenue`, `order_lines.line_margin` (kolumny generowane)

**Staging (Etap 3):** schemat `staging` (niewystawiony przez API), tabele 1:1 z plikami CSV, wszystkie kolumny jako `text` plus `import_run_id` i `row_no`. Tu wpadają też błędne wiersze, zanim walidacja je odrzuci.

**Log importu (Etap 3):** `import_runs` (status, czasy, liczby wierszy), `import_errors` (plik, nr wiersza, pole, opis po polsku).

**Indeksy pod filtry:** `order_lines(org_id, order_id)`, `orders(org_id, ordered_at)`, `orders(org_id, store_id, ordered_at)`, `products(org_id, category_id)`.

## 4. Zaszyte sygnały (`_truth.json`)

| sygnał | jak generator go tworzy | kto go sprawdza |
|---|---|---|
| sezonowość roczna | grudzień ×1,6, styczeń–luty ×0,8, wakacje zależne od kategorii | test generatora, F1 |
| sezonowość tygodniowa | sklepy: sobota najwyższa, niedziela niehandlowa (zamknięte poza niedzielami handlowymi); online: szczyt w niedzielę i poniedziałek wieczorem | test generatora |
| Black Friday i Cyber Monday | online ×4, sklepy ×1,8; promocja `BF-YYYY` na cały asortyment | F7 nie zgłasza fałszywego spadku |
| słabe sklepy | 3 sklepy z trwale niższym ruchem (×0,6) | F6: realizacja planu < 90% |
| spadek sklepu | 2 sklepy: −35% od wybranego tygodnia (nowa konkurencja) | F7 musi wykryć |
| spadek marży kategorii | 1 kategoria: wzrost kosztów zakupu o 15% przez 2 miesiące | F7 |
| churn | każdy klient ma czas życia z rozkładu wykładniczego; kohorty z promocji odchodzą szybciej | F3 |
| Pareto | popularność produktów z rozkładu Zipfa, ~20% SKU = ~80% przychodu | F2 (ABC) |
| region | ruch sklepu ∝ `size_m2` × `purchasing_power_index` | F1 z filtrem regionu |
| kurs EUR | koszt importowanych produktów w EUR → marża zależy od kursu NBP | F2 |

## 5. Rozmiar

Przy domyślnej konfiguracji (`scale = 1.0`): ~200 tys. zamówień, ~450 tys. pozycji, ~20 tys. klientów. Szacunkowo < 200 MB w bazie razem z indeksami, czyli dużo zapasu do limitu 500 MB darmowego planu. Test generatora sprawdza liczbę pozycji przy domyślnej konfiguracji (300–600 tys.).
