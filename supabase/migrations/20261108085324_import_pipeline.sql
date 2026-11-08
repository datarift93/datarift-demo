-- Stage 3: import pipeline (docs/requirements.md 2.4, docs/data-model.md).
--
--   1. staging   raw CSV rows, all text, tagged with import_run_id and row_no
--                (row_no = 1 for the first data row after the header)
--   2. validate  per file, set-based; every problem becomes a row in import_errors
--                with a Polish message (shown in F4)
--   3. model     valid rows are upserted by business code, so re-importing the same
--                files changes nothing (idempotent); costs are converted with NBP rates
--   4. log       import_runs: status, times, rows read / valid / rejected
--
-- The loader (pipeline: `datarift-pipeline import`) creates the run, COPYs the files into
-- staging and calls private.process_import(run_id). All logic lives here, so F4 can later
-- trigger the same function and every rule is testable with pgTAP.

-- Log -----------------------------------------------------------------------

create type public.import_status as enum ('running', 'success', 'partial', 'failed');

create table public.import_runs (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  status        public.import_status not null default 'running',
  source        text not null,             -- e.g. "generator seed=42 (2024-01-01..2025-12-31)"
  period_start  date not null,             -- orders outside [period_start, period_end] are rejected
  period_end    date not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  rows_read     integer,
  rows_valid    integer,
  rows_rejected integer,
  error_message text,                      -- set when the whole run failed
  unique (org_id, id),
  check (period_start <= period_end)
);

create index import_runs_org_started_idx on public.import_runs (org_id, started_at desc);

create table public.import_errors (
  id            bigint generated always as identity primary key,
  org_id        uuid not null,
  import_run_id bigint not null,
  file          text not null,
  row_no        integer not null,
  field         text not null,
  message       text not null,             -- Polish, shown in the UI
  foreign key (org_id, import_run_id) references public.import_runs (org_id, id) on delete cascade
);

create index import_errors_run_file_row_idx on public.import_errors (import_run_id, file, row_no);

-- Members (admin and demo) read the history; writes only through the import function.
do $$
declare
  t text;
begin
  foreach t in array array['import_runs', 'import_errors'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "members read own org" on public.%I for select to authenticated
         using (org_id in (select private.user_org_ids()))', t);
    execute format(
      'create trigger prevent_org_id_change before update on public.%I
         for each row execute function private.prevent_org_id_change()', t);
  end loop;
end $$;

revoke insert, update, delete on public.import_runs, public.import_errors from authenticated;

-- Staging -------------------------------------------------------------------
-- Not exposed through the Data API (only public and graphql_public are).

create schema staging;
revoke all on schema staging from public, anon, authenticated;

create table staging.fx_rates (import_run_id bigint not null, row_no integer not null,
  rate_date text, mid_rate text, table_no text);
create table staging.regions (import_run_id bigint not null, row_no integer not null,
  region_code text, name text, purchasing_power_index text);
create table staging.stores (import_run_id bigint not null, row_no integer not null,
  store_code text, name text, channel text, city text, region_code text, size_m2 text, opened_on text);
create table staging.categories (import_run_id bigint not null, row_no integer not null,
  category_code text, name text);
create table staging.products (import_run_id bigint not null, row_no integer not null,
  sku text, name text, category_code text, list_price text, purchase_currency text);
create table staging.customers (import_run_id bigint not null, row_no integer not null,
  customer_code text, region_code text, registered_on text);
create table staging.promotions (import_run_id bigint not null, row_no integer not null,
  promo_code text, name text, starts_on text, ends_on text, category_code text, sku text, discount_pct text);
create table staging.purchases (import_run_id bigint not null, row_no integer not null,
  purchase_code text, sku text, purchase_date text, quantity text, unit_cost text, currency text);
create table staging.orders (import_run_id bigint not null, row_no integer not null,
  order_code text, store_code text, customer_code text, ordered_at text);
create table staging.order_lines (import_run_id bigint not null, row_no integer not null,
  order_code text, line_no text, sku text, quantity text, unit_price text, promo_code text);
create table staging.budgets (import_run_id bigint not null, row_no integer not null,
  store_code text, month text, revenue_plan text);

do $$
declare
  t text;
begin
  foreach t in array array['fx_rates', 'regions', 'stores', 'categories', 'products', 'customers',
                           'promotions', 'purchases', 'orders', 'order_lines', 'budgets'] loop
    execute format('alter table staging.%I add primary key (import_run_id, row_no)', t);
  end loop;
end $$;

-- Helpers -------------------------------------------------------------------

-- These run millions of times per import, so they must be inlinable SQL functions:
-- no `set search_path` (that blocks inlining). They only call schema-qualified
-- pg_catalog functions (nullif is syntax), so they do not depend on the caller's search_path.

-- '' and NULL both mean "missing" (CSV empty field).
create function private.blank(v text) returns boolean
language sql immutable as $$ select nullif(pg_catalog.btrim(v), '') is null $$;

-- True when v is missing or parses as the given type.
create function private.parses(v text, type_name text) returns boolean
language sql stable as $$
  select nullif(pg_catalog.btrim(v), '') is null
      or pg_catalog.pg_input_is_valid(v, type_name)
$$;

revoke all on function private.blank(text), private.parses(text, text) from public;

-- Import --------------------------------------------------------------------

create function private.process_import(p_run_id bigint)
returns public.import_runs
language plpgsql
security definer
set search_path = ''
-- No statement_timeout here: a function-level SET cannot extend the caller's running
-- statement timer. The loader sets it on its session before calling.
as $$
declare
  v_run   public.import_runs;
  v_org   uuid;
  v_read  integer;
  v_rej   integer;
begin
  select * into v_run from public.import_runs where id = p_run_id for update;
  if not found then
    raise exception 'import run % not found', p_run_id;
  end if;
  if v_run.status <> 'running' then
    raise exception 'import run % is %, expected running', p_run_id, v_run.status;
  end if;
  v_org := v_run.org_id;

  -- One import per org at a time.
  perform pg_advisory_xact_lock(hashtextextended('import:' || v_org::text, 0));

  -- Freshly COPYed staging tables have no statistics; without them the planner assumes
  -- they are tiny and picks nested loops (minutes instead of seconds on ~450k rows).
  analyze staging.fx_rates, staging.regions, staging.stores, staging.categories,
          staging.products, staging.customers, staging.promotions, staging.purchases,
          staging.orders, staging.order_lines, staging.budgets;

  -- Files are validated and loaded in dependency order, so references are checked
  -- against the model (rows loaded earlier in this run or by previous runs).

  ------------------------------------------------------------------ fx_rates (global)
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'fx_eur_pln.csv', s.row_no, e.field, e.message
  from staging.fx_rates s
  cross join lateral (values
    ('rate_date', case when private.blank(s.rate_date) then 'Brak daty kursu'
                       when not private.parses(s.rate_date, 'date') then format('Niepoprawna data: %s', s.rate_date) end),
    ('mid_rate',  case when private.blank(s.mid_rate) then 'Brak kursu'
                       when not private.parses(s.mid_rate, 'numeric') then format('Niepoprawna liczba: %s', s.mid_rate)
                       when s.mid_rate::numeric <= 0 then format('Kurs musi być większy od zera: %s', s.mid_rate) end),
    ('table_no',  case when private.blank(s.table_no) then 'Brak numeru tabeli NBP' end)
  ) as e(field, message)
  where s.import_run_id = p_run_id and e.message is not null;

  insert into public.fx_rates (rate_date, mid_rate, table_no)
  select s.rate_date::date, s.mid_rate::numeric, s.table_no
  from staging.fx_rates s
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'fx_eur_pln.csv' and e.row_no = s.row_no)
  on conflict (rate_date) do update
    set mid_rate = excluded.mid_rate, table_no = excluded.table_no
    where (public.fx_rates.mid_rate, public.fx_rates.table_no)
          is distinct from (excluded.mid_rate, excluded.table_no);

  ------------------------------------------------------------------ regions
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'regions.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by region_code order by row_no) as dup
        from staging.regions where import_run_id = p_run_id) s
  cross join lateral (values
    ('region_code', case when private.blank(s.region_code) then 'Brak kodu województwa'
                         when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.region_code) end),
    ('name',        case when private.blank(s.name) then 'Brak nazwy' end),
    ('purchasing_power_index',
                    case when private.blank(s.purchasing_power_index) then 'Brak wskaźnika siły nabywczej'
                         when not private.parses(s.purchasing_power_index, 'numeric') then format('Niepoprawna liczba: %s', s.purchasing_power_index)
                         when s.purchasing_power_index::numeric <= 0 then 'Wskaźnik musi być większy od zera' end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.regions (org_id, region_code, name, purchasing_power_index)
  select v_org, s.region_code, s.name, s.purchasing_power_index::numeric
  from staging.regions s
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'regions.csv' and e.row_no = s.row_no)
  on conflict (org_id, region_code) do update
    set name = excluded.name, purchasing_power_index = excluded.purchasing_power_index
    where (public.regions.name, public.regions.purchasing_power_index)
          is distinct from (excluded.name, excluded.purchasing_power_index);

  ------------------------------------------------------------------ categories
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'categories.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by category_code order by row_no) as dup
        from staging.categories where import_run_id = p_run_id) s
  cross join lateral (values
    ('category_code', case when private.blank(s.category_code) then 'Brak kodu kategorii'
                           when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.category_code) end),
    ('name',          case when private.blank(s.name) then 'Brak nazwy' end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.categories (org_id, category_code, name)
  select v_org, s.category_code, s.name
  from staging.categories s
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'categories.csv' and e.row_no = s.row_no)
  on conflict (org_id, category_code) do update
    set name = excluded.name
    where public.categories.name is distinct from excluded.name;

  ------------------------------------------------------------------ stores
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'stores.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by store_code order by row_no) as dup
        from staging.stores where import_run_id = p_run_id) s
  left join public.regions r on r.org_id = v_org and r.region_code = s.region_code
  cross join lateral (values
    ('store_code', case when private.blank(s.store_code) then 'Brak kodu sklepu'
                        when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.store_code) end),
    ('name',       case when private.blank(s.name) then 'Brak nazwy' end),
    ('channel',    case when coalesce(s.channel, '') not in ('store', 'online')
                        then format('Nieznany kanał: „%s” (dozwolone: store, online)', coalesce(s.channel, '')) end),
    ('city',       case when s.channel = 'store' and private.blank(s.city) then 'Brak miasta dla sklepu stacjonarnego'
                        when s.channel = 'online' and not private.blank(s.city) then 'Sklep internetowy nie może mieć miasta' end),
    ('region_code',case when s.channel = 'store' and private.blank(s.region_code) then 'Brak województwa dla sklepu stacjonarnego'
                        when not private.blank(s.region_code) and r.id is null then format('Nieznane województwo: %s', s.region_code)
                        when s.channel = 'online' and not private.blank(s.region_code) then 'Sklep internetowy nie może mieć województwa' end),
    ('size_m2',    case when not private.parses(s.size_m2, 'integer') then format('Niepoprawna liczba całkowita: %s', s.size_m2)
                        when s.channel = 'store' and private.blank(s.size_m2) then 'Brak powierzchni dla sklepu stacjonarnego'
                        when nullif(btrim(s.size_m2), '')::integer <= 0 then 'Powierzchnia musi być większa od zera'
                        when s.channel = 'online' and not private.blank(s.size_m2) then 'Sklep internetowy nie może mieć powierzchni' end),
    ('opened_on',  case when private.blank(s.opened_on) then 'Brak daty otwarcia'
                        when not private.parses(s.opened_on, 'date') then format('Niepoprawna data: %s', s.opened_on) end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
  select v_org, s.store_code, s.name, s.channel::public.sales_channel, nullif(s.city, ''), r.id,
         nullif(s.size_m2, '')::integer, s.opened_on::date
  from staging.stores s
  left join public.regions r on r.org_id = v_org and r.region_code = s.region_code
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'stores.csv' and e.row_no = s.row_no)
  on conflict (org_id, store_code) do update
    set name = excluded.name, channel = excluded.channel, city = excluded.city,
        region_id = excluded.region_id, size_m2 = excluded.size_m2, opened_on = excluded.opened_on
    where (public.stores.name, public.stores.channel, public.stores.city, public.stores.region_id,
           public.stores.size_m2, public.stores.opened_on)
          is distinct from (excluded.name, excluded.channel, excluded.city, excluded.region_id,
                            excluded.size_m2, excluded.opened_on);

  ------------------------------------------------------------------ products
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'products.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by sku order by row_no) as dup
        from staging.products where import_run_id = p_run_id) s
  left join public.categories c on c.org_id = v_org and c.category_code = s.category_code
  cross join lateral (values
    ('sku',           case when private.blank(s.sku) then 'Brak SKU'
                           when s.dup > 1 then format('Duplikat: SKU %s występuje wcześniej w pliku', s.sku) end),
    ('name',          case when private.blank(s.name) then 'Brak nazwy' end),
    ('category_code', case when private.blank(s.category_code) then 'Brak kategorii'
                           when c.id is null then format('Nieznana kategoria: %s', s.category_code) end),
    ('list_price',    case when private.blank(s.list_price) then 'Brak ceny'
                           when not private.parses(s.list_price, 'numeric') then format('Niepoprawna liczba: %s', s.list_price)
                           when s.list_price::numeric < 0 then format('Cena nie może być ujemna: %s', s.list_price) end),
    ('purchase_currency',
                      case when coalesce(s.purchase_currency, '') not in ('PLN', 'EUR')
                           then format('Nieobsługiwana waluta: „%s” (dozwolone: PLN, EUR)', coalesce(s.purchase_currency, '')) end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency)
  select v_org, s.sku, s.name, c.id, s.list_price::numeric, s.purchase_currency::public.purchase_currency
  from staging.products s
  join public.categories c on c.org_id = v_org and c.category_code = s.category_code
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'products.csv' and e.row_no = s.row_no)
  on conflict (org_id, sku) do update
    set name = excluded.name, category_id = excluded.category_id,
        list_price = excluded.list_price, purchase_currency = excluded.purchase_currency
    where (public.products.name, public.products.category_id, public.products.list_price,
           public.products.purchase_currency)
          is distinct from (excluded.name, excluded.category_id, excluded.list_price,
                            excluded.purchase_currency);

  ------------------------------------------------------------------ customers
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'customers.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by customer_code order by row_no) as dup
        from staging.customers where import_run_id = p_run_id) s
  left join public.regions r on r.org_id = v_org and r.region_code = s.region_code
  cross join lateral (values
    ('customer_code', case when private.blank(s.customer_code) then 'Brak kodu klienta'
                           when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.customer_code) end),
    ('region_code',   case when private.blank(s.region_code) then 'Brak województwa'
                           when r.id is null then format('Nieznane województwo: %s', s.region_code) end),
    ('registered_on', case when private.blank(s.registered_on) then 'Brak daty rejestracji'
                           when not private.parses(s.registered_on, 'date') then format('Niepoprawna data: %s', s.registered_on) end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.customers (org_id, customer_code, region_id, registered_on)
  select v_org, s.customer_code, r.id, s.registered_on::date
  from staging.customers s
  join public.regions r on r.org_id = v_org and r.region_code = s.region_code
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'customers.csv' and e.row_no = s.row_no)
  on conflict (org_id, customer_code) do update
    set region_id = excluded.region_id, registered_on = excluded.registered_on
    where (public.customers.region_id, public.customers.registered_on)
          is distinct from (excluded.region_id, excluded.registered_on);

  ------------------------------------------------------------------ promotions
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'promotions.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by promo_code order by row_no) as dup
        from staging.promotions where import_run_id = p_run_id) s
  left join public.categories c on c.org_id = v_org and c.category_code = s.category_code
  left join public.products p on p.org_id = v_org and p.sku = s.sku
  cross join lateral (values
    ('promo_code',    case when private.blank(s.promo_code) then 'Brak kodu promocji'
                           when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.promo_code) end),
    ('name',          case when private.blank(s.name) then 'Brak nazwy' end),
    ('starts_on',     case when private.blank(s.starts_on) then 'Brak daty początku'
                           when not private.parses(s.starts_on, 'date') then format('Niepoprawna data: %s', s.starts_on) end),
    ('ends_on',       case when private.blank(s.ends_on) then 'Brak daty końca'
                           when not private.parses(s.ends_on, 'date') then format('Niepoprawna data: %s', s.ends_on)
                           -- nested CASE: AND does not guarantee the cast runs only after the parse check
                           when (case when private.parses(s.starts_on, 'date')
                                      then s.ends_on::date < nullif(btrim(s.starts_on), '')::date end)
                           then 'Data końca jest przed datą początku' end),
    ('category_code', case when not private.blank(s.category_code) and c.id is null then format('Nieznana kategoria: %s', s.category_code)
                           when not private.blank(s.category_code) and not private.blank(s.sku)
                           then 'Promocja może dotyczyć kategorii albo produktu, nie obu naraz' end),
    ('sku',           case when not private.blank(s.sku) and p.id is null then format('Nieznany produkt (SKU %s)', s.sku) end),
    ('discount_pct',  case when private.blank(s.discount_pct) then 'Brak rabatu'
                           when not private.parses(s.discount_pct, 'numeric') then format('Niepoprawna liczba: %s', s.discount_pct)
                           when s.discount_pct::numeric not between 0 and 1 then format('Rabat musi być między 0 a 1: %s', s.discount_pct) end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.promotions (org_id, promo_code, name, starts_on, ends_on, category_id, product_id, discount_pct)
  select v_org, s.promo_code, s.name, s.starts_on::date, s.ends_on::date, c.id, p.id, s.discount_pct::numeric
  from staging.promotions s
  left join public.categories c on c.org_id = v_org and c.category_code = s.category_code
  left join public.products p on p.org_id = v_org and p.sku = s.sku
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'promotions.csv' and e.row_no = s.row_no)
  on conflict (org_id, promo_code) do update
    set name = excluded.name, starts_on = excluded.starts_on, ends_on = excluded.ends_on,
        category_id = excluded.category_id, product_id = excluded.product_id,
        discount_pct = excluded.discount_pct
    where (public.promotions.name, public.promotions.starts_on, public.promotions.ends_on,
           public.promotions.category_id, public.promotions.product_id, public.promotions.discount_pct)
          is distinct from (excluded.name, excluded.starts_on, excluded.ends_on,
                            excluded.category_id, excluded.product_id, excluded.discount_pct);

  ------------------------------------------------------------------ purchases
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'purchases.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by purchase_code order by row_no) as dup
        from staging.purchases where import_run_id = p_run_id) s
  left join public.products p on p.org_id = v_org and p.sku = s.sku
  cross join lateral (values
    ('purchase_code', case when private.blank(s.purchase_code) then 'Brak kodu zakupu'
                           when s.dup > 1 then format('Duplikat: kod %s występuje wcześniej w pliku', s.purchase_code) end),
    ('sku',           case when private.blank(s.sku) then 'Brak SKU'
                           when p.id is null then format('Nieznany produkt (SKU %s)', s.sku) end),
    ('purchase_date', case when private.blank(s.purchase_date) then 'Brak daty zakupu'
                           when not private.parses(s.purchase_date, 'date') then format('Niepoprawna data: %s', s.purchase_date)
                           when s.currency = 'EUR' and not exists (
                             select 1 from public.fx_rates f where f.rate_date <= s.purchase_date::date
                               and f.rate_date > s.purchase_date::date - 7)
                           then format('Brak kursu NBP EUR z dnia %s ani z 7 dni wcześniej', s.purchase_date) end),
    ('quantity',      case when private.blank(s.quantity) then 'Brak ilości'
                           when not private.parses(s.quantity, 'integer') then format('Niepoprawna liczba całkowita: %s', s.quantity)
                           when s.quantity::integer <= 0 then format('Ilość musi być większa od zera: %s', s.quantity) end),
    ('unit_cost',     case when private.blank(s.unit_cost) then 'Brak kosztu jednostkowego'
                           when not private.parses(s.unit_cost, 'numeric') then format('Niepoprawna liczba: %s', s.unit_cost)
                           when s.unit_cost::numeric < 0 then format('Koszt nie może być ujemny: %s', s.unit_cost) end),
    ('currency',      case when coalesce(s.currency, '') not in ('PLN', 'EUR')
                           then format('Nieobsługiwana waluta: „%s” (dozwolone: PLN, EUR)', coalesce(s.currency, '')) end)
  ) as e(field, message)
  where e.message is not null;

  -- NBP rate from the purchase date or the last publication day before it (requirements 2.3).
  insert into public.purchases (org_id, purchase_code, product_id, purchase_date, quantity, unit_cost,
                                currency, fx_rate, unit_cost_pln)
  -- Casts only in the select list of the inner query, which runs after the error filter.
  select v_org, v.purchase_code, v.product_id, v.purchase_date, v.quantity, v.unit_cost,
         v.currency, fx.rate, round(v.unit_cost * fx.rate, 2)
  from (
    select s.purchase_code, p.id as product_id, s.purchase_date::date as purchase_date,
           s.quantity::integer as quantity, s.unit_cost::numeric as unit_cost,
           s.currency::public.purchase_currency as currency
    from staging.purchases s
    join public.products p on p.org_id = v_org and p.sku = s.sku
    where s.import_run_id = p_run_id
      and not exists (select 1 from public.import_errors e
                      where e.import_run_id = p_run_id and e.file = 'purchases.csv' and e.row_no = s.row_no)
    offset 0  -- optimization fence: keep the filter before the casts
  ) v
  cross join lateral (
    select case when v.currency = 'PLN' then 1::numeric
                else (select f.mid_rate from public.fx_rates f
                      where f.rate_date <= v.purchase_date
                      order by f.rate_date desc limit 1) end as rate
  ) fx
  on conflict (org_id, purchase_code) do update
    set product_id = excluded.product_id, purchase_date = excluded.purchase_date,
        quantity = excluded.quantity, unit_cost = excluded.unit_cost, currency = excluded.currency,
        fx_rate = excluded.fx_rate, unit_cost_pln = excluded.unit_cost_pln
    where (public.purchases.product_id, public.purchases.purchase_date, public.purchases.quantity,
           public.purchases.unit_cost, public.purchases.currency, public.purchases.fx_rate,
           public.purchases.unit_cost_pln)
          is distinct from (excluded.product_id, excluded.purchase_date, excluded.quantity,
                            excluded.unit_cost, excluded.currency, excluded.fx_rate, excluded.unit_cost_pln);

  ------------------------------------------------------------------ orders
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'orders.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by order_code order by row_no) as dup
        from staging.orders where import_run_id = p_run_id) s
  left join public.stores st on st.org_id = v_org and st.store_code = s.store_code
  left join public.customers c on c.org_id = v_org and c.customer_code = s.customer_code
  cross join lateral (values
    ('order_code',    case when private.blank(s.order_code) then 'Brak numeru zamówienia'
                           when s.dup > 1 then format('Duplikat: zamówienie %s występuje wcześniej w pliku', s.order_code) end),
    ('store_code',    case when private.blank(s.store_code) then 'Brak sklepu'
                           when st.id is null then format('Nieznany sklep: %s', s.store_code) end),
    ('customer_code', case when not private.blank(s.customer_code) and c.id is null
                           then format('Nieznany klient: %s', s.customer_code) end),
    ('ordered_at',    case when private.blank(s.ordered_at) then 'Brak daty zamówienia'
                           when not private.parses(s.ordered_at, 'timestamptz') then format('Niepoprawna data i godzina: %s', s.ordered_at)
                           when (s.ordered_at::timestamptz at time zone 'Europe/Warsaw')::date
                                not between v_run.period_start and v_run.period_end
                           then format('Data %s poza okresem importu (%s – %s)',
                                       to_char((s.ordered_at::timestamptz at time zone 'Europe/Warsaw')::date, 'DD.MM.YYYY'),
                                       to_char(v_run.period_start, 'DD.MM.YYYY'), to_char(v_run.period_end, 'DD.MM.YYYY')) end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.orders (org_id, order_code, store_id, customer_id, ordered_at)
  select v_org, s.order_code, st.id, c.id, s.ordered_at::timestamptz
  from staging.orders s
  join public.stores st on st.org_id = v_org and st.store_code = s.store_code
  left join public.customers c on c.org_id = v_org and c.customer_code = s.customer_code
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'orders.csv' and e.row_no = s.row_no)
  on conflict (org_id, order_code) do update
    set store_id = excluded.store_id, customer_id = excluded.customer_id, ordered_at = excluded.ordered_at
    where (public.orders.store_id, public.orders.customer_id, public.orders.ordered_at)
          is distinct from (excluded.store_id, excluded.customer_id, excluded.ordered_at);

  -- The model tables may have just grown from empty; refresh statistics before the big joins.
  analyze public.products, public.purchases, public.orders, public.promotions;

  ------------------------------------------------------------------ order_lines
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'order_lines.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by order_code, line_no order by row_no) as dup
        from staging.order_lines where import_run_id = p_run_id) s
  left join public.orders o on o.org_id = v_org and o.order_code = s.order_code
  left join public.products p on p.org_id = v_org and p.sku = s.sku
  left join public.promotions pm on pm.org_id = v_org and pm.promo_code = s.promo_code
  cross join lateral (values
    ('order_code', case when private.blank(s.order_code) then 'Brak numeru zamówienia'
                        when o.id is null then format('Nieznane lub odrzucone zamówienie: %s', s.order_code) end),
    ('line_no',    case when private.blank(s.line_no) then 'Brak numeru pozycji'
                        when not private.parses(s.line_no, 'integer') then format('Niepoprawna liczba całkowita: %s', s.line_no)
                        when s.line_no::integer <= 0 then 'Numer pozycji musi być większy od zera'
                        when s.dup > 1 then format('Duplikat: pozycja %s zamówienia %s występuje wcześniej w pliku', s.line_no, s.order_code) end),
    ('sku',        case when private.blank(s.sku) then 'Brak SKU'
                        when p.id is null then format('Nieznany produkt (SKU %s)', s.sku) end),
    ('quantity',   case when private.blank(s.quantity) then 'Brak ilości'
                        when not private.parses(s.quantity, 'integer') then format('Niepoprawna liczba całkowita: %s', s.quantity)
                        when s.quantity::integer <= 0 then format('Ilość musi być większa od zera: %s', s.quantity) end),
    ('unit_price', case when private.blank(s.unit_price) then 'Brak ceny'
                        when not private.parses(s.unit_price, 'numeric') then format('Niepoprawna liczba: %s', s.unit_price)
                        when s.unit_price::numeric < 0 then format('Cena nie może być ujemna: %s', s.unit_price) end),
    ('promo_code', case when not private.blank(s.promo_code) and pm.id is null
                        then format('Nieznana promocja: %s', s.promo_code) end)
  ) as e(field, message)
  where e.message is not null;

  -- Unit cost of a line: weighted average purchase cost (PLN) of the product over the
  -- 90 days up to the order date (docs/data-model.md section 3). Computed once per
  -- product and day, then joined to the lines.
  drop table if exists pg_temp.import_daily_cost;  -- a second run in the same transaction
  create temporary table import_daily_cost on commit drop as
  with days as (
    select distinct (o.ordered_at at time zone 'Europe/Warsaw')::date as day
    from public.orders o
    join staging.orders s on s.import_run_id = p_run_id and s.order_code = o.order_code
    where o.org_id = v_org
  )
  select pu.product_id, d.day,
         round(sum(pu.quantity * pu.unit_cost_pln) / sum(pu.quantity), 2) as unit_cost_pln
  from days d
  join public.purchases pu
    on pu.org_id = v_org and pu.purchase_date > d.day - 90 and pu.purchase_date <= d.day
  group by pu.product_id, d.day;

  create index on import_daily_cost (product_id, day);
  analyze import_daily_cost;

  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price,
                                  promotion_id, unit_cost_pln)
  select v_org, o.id, s.line_no::integer, p.id, s.quantity::integer, s.unit_price::numeric,
         pm.id, dc.unit_cost_pln
  from staging.order_lines s
  join public.orders o on o.org_id = v_org and o.order_code = s.order_code
  join public.products p on p.org_id = v_org and p.sku = s.sku
  left join public.promotions pm on pm.org_id = v_org and pm.promo_code = s.promo_code
  left join import_daily_cost dc
    on dc.product_id = p.id and dc.day = (o.ordered_at at time zone 'Europe/Warsaw')::date
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'order_lines.csv' and e.row_no = s.row_no)
  on conflict (org_id, order_id, line_no) do update
    set product_id = excluded.product_id, quantity = excluded.quantity, unit_price = excluded.unit_price,
        promotion_id = excluded.promotion_id, unit_cost_pln = excluded.unit_cost_pln
    where (public.order_lines.product_id, public.order_lines.quantity, public.order_lines.unit_price,
           public.order_lines.promotion_id, public.order_lines.unit_cost_pln)
          is distinct from (excluded.product_id, excluded.quantity, excluded.unit_price,
                            excluded.promotion_id, excluded.unit_cost_pln);

  ------------------------------------------------------------------ budgets
  insert into public.import_errors (org_id, import_run_id, file, row_no, field, message)
  select v_org, p_run_id, 'budgets.csv', s.row_no, e.field, e.message
  from (select *, row_number() over (partition by store_code, month order by row_no) as dup
        from staging.budgets where import_run_id = p_run_id) s
  left join public.stores st on st.org_id = v_org and st.store_code = s.store_code
  cross join lateral (values
    ('store_code',   case when private.blank(s.store_code) then 'Brak sklepu'
                          when st.id is null then format('Nieznany sklep: %s', s.store_code) end),
    ('month',        case when private.blank(s.month) then 'Brak miesiąca'
                          when not private.parses(s.month, 'date') then format('Niepoprawna data: %s', s.month)
                          when extract(day from s.month::date) <> 1 then format('Miesiąc musi być pierwszym dniem miesiąca: %s', s.month)
                          when s.dup > 1 then format('Duplikat: budżet sklepu %s na %s występuje wcześniej w pliku', s.store_code, s.month) end),
    ('revenue_plan', case when private.blank(s.revenue_plan) then 'Brak planu'
                          when not private.parses(s.revenue_plan, 'numeric') then format('Niepoprawna liczba: %s', s.revenue_plan)
                          when s.revenue_plan::numeric < 0 then 'Plan nie może być ujemny' end)
  ) as e(field, message)
  where e.message is not null;

  insert into public.budgets (org_id, store_id, month, revenue_plan)
  select v_org, st.id, s.month::date, s.revenue_plan::numeric
  from staging.budgets s
  join public.stores st on st.org_id = v_org and st.store_code = s.store_code
  where s.import_run_id = p_run_id
    and not exists (select 1 from public.import_errors e
                    where e.import_run_id = p_run_id and e.file = 'budgets.csv' and e.row_no = s.row_no)
  on conflict (org_id, store_id, month) do update
    set revenue_plan = excluded.revenue_plan
    where public.budgets.revenue_plan is distinct from excluded.revenue_plan;

  ------------------------------------------------------------------ log
  select (select count(*) from staging.fx_rates    where import_run_id = p_run_id)
       + (select count(*) from staging.regions     where import_run_id = p_run_id)
       + (select count(*) from staging.stores      where import_run_id = p_run_id)
       + (select count(*) from staging.categories  where import_run_id = p_run_id)
       + (select count(*) from staging.products    where import_run_id = p_run_id)
       + (select count(*) from staging.customers   where import_run_id = p_run_id)
       + (select count(*) from staging.promotions  where import_run_id = p_run_id)
       + (select count(*) from staging.purchases   where import_run_id = p_run_id)
       + (select count(*) from staging.orders      where import_run_id = p_run_id)
       + (select count(*) from staging.order_lines where import_run_id = p_run_id)
       + (select count(*) from staging.budgets     where import_run_id = p_run_id)
    into v_read;

  select count(*) into v_rej
  from (select distinct file, row_no from public.import_errors where import_run_id = p_run_id) r;

  update public.import_runs
  set status = case when v_read = 0 or v_rej = v_read then 'failed'::public.import_status
                    when v_rej > 0 then 'partial'
                    else 'success' end,
      finished_at = clock_timestamp(),
      rows_read = v_read,
      rows_valid = v_read - v_rej,
      rows_rejected = v_rej
  where id = p_run_id
  returning * into v_run;

  -- Raw rows are not kept (free-tier size); rejected rows stay described in import_errors.
  delete from staging.fx_rates    where import_run_id = p_run_id;
  delete from staging.regions     where import_run_id = p_run_id;
  delete from staging.stores      where import_run_id = p_run_id;
  delete from staging.categories  where import_run_id = p_run_id;
  delete from staging.products    where import_run_id = p_run_id;
  delete from staging.customers   where import_run_id = p_run_id;
  delete from staging.promotions  where import_run_id = p_run_id;
  delete from staging.purchases   where import_run_id = p_run_id;
  delete from staging.orders      where import_run_id = p_run_id;
  delete from staging.order_lines where import_run_id = p_run_id;
  delete from staging.budgets     where import_run_id = p_run_id;

  return v_run;
end $$;

revoke all on function private.process_import(bigint) from public, anon, authenticated;

-- Demo organization: the target of the demo import, locally and in production.
insert into public.orgs (id, slug, name)
values ('00000000-0000-0000-0000-00000000a001', 'wisla-demo', 'Wisła (demo)')
on conflict (id) do nothing;
