-- Import pipeline: validation rules, model upsert, NBP conversion, 90-day cost, log,
-- idempotency and access. Uses a small hand-made dataset in its own org.
begin;
create extension if not exists pgtap with schema extensions;

select plan(37);

insert into public.orgs (id, slug, name) values ('30000000-0000-0000-0000-00000000000a', 'imp-test', 'Import test');
insert into auth.users (id, email) values ('30000000-0000-0000-0000-0000000000d1', 'imp-demo@test.local');
insert into public.org_members (org_id, user_id, role)
values ('30000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-0000000000d1', 'demo');

create function pg_temp.new_run() returns bigint language sql as $$
  insert into public.import_runs (org_id, source, period_start, period_end)
  values ('30000000-0000-0000-0000-00000000000a', 'pgtap', '2025-01-01', '2025-12-31')
  returning id
$$;

-- Stage the same files for a run. Each comment names the rule a broken row exercises.
create function pg_temp.stage(r bigint) returns void language sql as $$
  insert into staging.fx_rates values
    (r, 1, '2025-01-02', '4.2500', '001/A/NBP/2025'),
    (r, 2, '2025-01-03', '4.2600', '002/A/NBP/2025'),
    (r, 3, '2025-01-0x', 'abc', '');                                   -- bad date, number, table
  insert into staging.regions values
    (r, 1, '14', 'mazowieckie', '1.200'),
    (r, 2, '14', 'duplikat', '1.000'),                                 -- duplicate code
    (r, 3, '', 'bez kodu', '-1');                                      -- blank code, index <= 0
  insert into staging.categories values (r, 1, 'HOME', 'Dom i ogród');
  insert into staging.stores values
    (r, 1, 'WAW-01', 'Warszawa 1', 'store', 'Warszawa', '14', '500', '2020-01-01'),
    (r, 2, 'ONLINE', 'Sklep internetowy', 'online', null, null, null, '2020-01-01'),
    (r, 3, 'BAD-01', 'Zły', 'mall', 'Kraków', '99', 'abc', '2020-13-01'); -- 4 problems
  insert into staging.products values
    (r, 1, 'HOME-0001', 'Lampa', 'HOME', '100.00', 'EUR'),
    (r, 2, 'HOME-0002', 'Zła', 'NOPE', '-5', 'USD');                   -- category, price, currency
  insert into staging.customers values (r, 1, 'C1', '14', '2024-01-01');
  insert into staging.promotions values
    (r, 1, 'P1', 'Styczeń', '2025-01-01', '2025-01-31', 'HOME', null, '0.2'),
    (r, 2, 'P2', 'Zła', '2025-02-10', '2025-02-01', 'HOME', 'HOME-0001', '2'); -- dates, both, discount
  insert into staging.purchases values
    (r, 1, 'PU1', 'HOME-0001', '2025-01-04', '10', '20.00', 'EUR'),    -- Saturday: rate of 03.01
    (r, 2, 'PU2', 'HOME-0001', '2024-06-01', '5', '20.00', 'EUR');     -- no NBP rate near the date
  insert into staging.orders values
    (r, 1, 'O1', 'WAW-01', 'C1', '2025-01-10T12:00:00+01:00'),
    (r, 2, 'O2', 'ONLINE', null, '2025-01-11T10:00:00+01:00'),
    (r, 3, 'O3', 'WAW-01', 'C9', '2023-01-01T10:00:00+01:00'),         -- unknown customer, out of range
    (r, 4, 'O1', 'WAW-01', null, '2025-01-12T10:00:00+01:00');         -- duplicate order
  insert into staging.order_lines values
    (r, 1, 'O1', '1', 'HOME-0001', '2', '150.00', 'P1'),
    (r, 2, 'O2', '1', 'HOME-0001', '1', '100.00', null),
    (r, 3, 'O1', '1', 'HOME-0001', '1', '1.00', null),                 -- duplicate line
    (r, 4, 'O3', '1', 'HOME-0001', '1', '1.00', null),                 -- order was rejected
    (r, 5, 'O1', '2', 'NOPE', '0', '-1', 'PX');                        -- sku, qty, price, promo
  insert into staging.budgets values
    (r, 1, 'WAW-01', '2025-01-01', '10000'),
    (r, 2, 'WAW-01', '2025-01-15', 'x');                               -- not 1st of month, bad plan
$$;

create function pg_temp.has_error(r bigint, f text, n int, fld text, msg text) returns boolean
language sql as $$
  select exists (select 1 from public.import_errors
                 where import_run_id = r and file = f and row_no = n and field = fld and message = msg)
$$;

-- First run ----------------------------------------------------------------
create temp table runs (n int, id bigint);
insert into runs select 1, pg_temp.new_run();
select pg_temp.stage((select id from runs where n = 1));
select private.process_import((select id from runs where n = 1));

select results_eq(
  $$ select status::text, rows_read, rows_valid, rows_rejected from public.import_runs
     where id = (select id from runs where n = 1) $$,
  $$ values ('partial', 28, 15, 13) $$,
  'run is partial with 28 read, 15 valid, 13 rejected');

select isnt((select finished_at from public.import_runs where id = (select id from runs where n = 1)),
            null, 'finished_at is set');

-- One check per rule family, with the exact Polish message where it matters.
select ok(pg_temp.has_error((select id from runs where n = 1), 'fx_eur_pln.csv', 3, 'mid_rate', 'Niepoprawna liczba: abc'), 'fx: bad number');
select ok(pg_temp.has_error((select id from runs where n = 1), 'regions.csv', 2, 'region_code', 'Duplikat: kod 14 występuje wcześniej w pliku'), 'regions: duplicate');
select ok(pg_temp.has_error((select id from runs where n = 1), 'regions.csv', 3, 'region_code', 'Brak kodu województwa'), 'regions: blank code');
select ok(pg_temp.has_error((select id from runs where n = 1), 'stores.csv', 3, 'channel', 'Nieznany kanał: „mall” (dozwolone: store, online)'), 'stores: unknown channel');
select ok(pg_temp.has_error((select id from runs where n = 1), 'stores.csv', 3, 'region_code', 'Nieznane województwo: 99'), 'stores: unknown region');
select ok(pg_temp.has_error((select id from runs where n = 1), 'stores.csv', 3, 'opened_on', 'Niepoprawna data: 2020-13-01'), 'stores: bad date');
select ok(pg_temp.has_error((select id from runs where n = 1), 'products.csv', 2, 'purchase_currency', 'Nieobsługiwana waluta: „USD” (dozwolone: PLN, EUR)'), 'products: currency');
select ok(pg_temp.has_error((select id from runs where n = 1), 'products.csv', 2, 'list_price', 'Cena nie może być ujemna: -5'), 'products: negative price');
select ok(pg_temp.has_error((select id from runs where n = 1), 'promotions.csv', 2, 'ends_on', 'Data końca jest przed datą początku'), 'promotions: end before start');
select ok(pg_temp.has_error((select id from runs where n = 1), 'promotions.csv', 2, 'category_code', 'Promocja może dotyczyć kategorii albo produktu, nie obu naraz'), 'promotions: both targets');
select ok(pg_temp.has_error((select id from runs where n = 1), 'purchases.csv', 2, 'purchase_date', 'Brak kursu NBP EUR z dnia 2024-06-01 ani z 7 dni wcześniej'), 'purchases: no NBP rate');
select ok(pg_temp.has_error((select id from runs where n = 1), 'orders.csv', 3, 'customer_code', 'Nieznany klient: C9'), 'orders: unknown customer');
select ok(pg_temp.has_error((select id from runs where n = 1), 'orders.csv', 3, 'ordered_at', 'Data 01.01.2023 poza okresem importu (01.01.2025 – 31.12.2025)'), 'orders: out of period');
select ok(pg_temp.has_error((select id from runs where n = 1), 'orders.csv', 4, 'order_code', 'Duplikat: zamówienie O1 występuje wcześniej w pliku'), 'orders: duplicate');
select ok(pg_temp.has_error((select id from runs where n = 1), 'order_lines.csv', 3, 'line_no', 'Duplikat: pozycja 1 zamówienia O1 występuje wcześniej w pliku'), 'lines: duplicate');
select ok(pg_temp.has_error((select id from runs where n = 1), 'order_lines.csv', 4, 'order_code', 'Nieznane lub odrzucone zamówienie: O3'), 'lines: rejected order');
select ok(pg_temp.has_error((select id from runs where n = 1), 'order_lines.csv', 5, 'sku', 'Nieznany produkt (SKU NOPE)'), 'lines: unknown sku');
select ok(pg_temp.has_error((select id from runs where n = 1), 'order_lines.csv', 5, 'quantity', 'Ilość musi być większa od zera: 0'), 'lines: zero quantity');
select ok(pg_temp.has_error((select id from runs where n = 1), 'budgets.csv', 2, 'month', 'Miesiąc musi być pierwszym dniem miesiąca: 2025-01-15'), 'budgets: not first of month');

-- Model ----------------------------------------------------------------------
select results_eq(
  $$ select (select count(*) from public.stores where org_id = '30000000-0000-0000-0000-00000000000a')::int,
            (select count(*) from public.orders where org_id = '30000000-0000-0000-0000-00000000000a')::int,
            (select count(*) from public.order_lines where org_id = '30000000-0000-0000-0000-00000000000a')::int $$,
  $$ values (2, 2, 2) $$,
  'only valid rows reach the model (2 stores, 2 orders, 2 lines)');

select results_eq(
  $$ select fx_rate, unit_cost_pln from public.purchases
     where org_id = '30000000-0000-0000-0000-00000000000a' and purchase_code = 'PU1' $$,
  $$ values (4.2600::numeric, 85.20::numeric) $$,
  'EUR purchase uses the NBP rate of the last publication day before a Saturday');

select results_eq(
  $$ select l.unit_cost_pln, l.line_revenue, l.line_margin
     from public.order_lines l join public.orders o on o.id = l.order_id
     where o.org_id = '30000000-0000-0000-0000-00000000000a' and o.order_code = 'O1' and l.line_no = 1 $$,
  $$ values (85.20::numeric, 300.00::numeric, 129.60::numeric) $$,
  'line cost = 90-day weighted purchase cost; revenue and margin follow');

select is((select o.customer_id is null from public.orders o
           where o.org_id = '30000000-0000-0000-0000-00000000000a' and o.order_code = 'O2'),
          true, 'anonymous order keeps a null customer');

select is((select count(*)::int from staging.order_lines where import_run_id = (select id from runs where n = 1)),
          0, 'staging rows are removed after the run');

-- Idempotency: the same files again change nothing ------------------------------
create temp table before as
  select 'orders' t, count(*) c, sum(hashtext(o::text)) h from public.orders o where org_id = '30000000-0000-0000-0000-00000000000a'
  union all select 'order_lines', count(*), sum(hashtext(l::text)) from public.order_lines l where org_id = '30000000-0000-0000-0000-00000000000a'
  union all select 'purchases', count(*), sum(hashtext(p::text)) from public.purchases p where org_id = '30000000-0000-0000-0000-00000000000a';

insert into runs select 2, pg_temp.new_run();
select pg_temp.stage((select id from runs where n = 2));
select private.process_import((select id from runs where n = 2));

select results_eq(
  $$ select status::text, rows_rejected from public.import_runs where id = (select id from runs where n = 2) $$,
  $$ values ('partial', 13) $$,
  'second run reports the same rejections');

select bag_eq(
  $$ select 'orders' t, count(*) c, sum(hashtext(o::text)) h from public.orders o where org_id = '30000000-0000-0000-0000-00000000000a'
     union all select 'order_lines', count(*), sum(hashtext(l::text)) from public.order_lines l where org_id = '30000000-0000-0000-0000-00000000000a'
     union all select 'purchases', count(*), sum(hashtext(p::text)) from public.purchases p where org_id = '30000000-0000-0000-0000-00000000000a' $$,
  $$ select * from before $$,
  're-importing the same files leaves the model unchanged (no duplicates, no updates)');

-- A changed value is updated in place --------------------------------------------
insert into runs select 3, pg_temp.new_run();
select pg_temp.stage((select id from runs where n = 3));
update staging.budgets set revenue_plan = '12000' where import_run_id = (select id from runs where n = 3) and row_no = 1;
select private.process_import((select id from runs where n = 3));
select results_eq(
  $$ select count(*)::int, max(revenue_plan) from public.budgets where org_id = '30000000-0000-0000-0000-00000000000a' $$,
  $$ values (1, 12000.00::numeric) $$,
  'a changed value updates the existing row');

-- Run states -------------------------------------------------------------------
insert into runs select 4, pg_temp.new_run();
select private.process_import((select id from runs where n = 4));
select is((select status::text from public.import_runs where id = (select id from runs where n = 4)),
          'failed', 'a run with no rows is failed');

select throws_ok(
  format('select private.process_import(%s)', (select id from runs where n = 1)),
  'P0001', null, 'a finished run cannot be processed again');

-- Access -----------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"30000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;

select is((select count(*)::int from public.import_runs), 4, 'demo member reads the run history of its org');
select cmp_ok((select count(*)::int from public.import_errors), '>', 0, 'demo member reads import errors');
select throws_ok($$ select private.process_import(1) $$, '42501', null, 'demo member cannot run an import');
select throws_ok($$ select * from staging.orders $$, '42501', null, 'staging is not readable through the API roles');
select throws_ok(
  $$ insert into public.import_runs (org_id, source, period_start, period_end)
     values ('30000000-0000-0000-0000-00000000000a', 'x', '2025-01-01', '2025-12-31') $$,
  '42501', null, 'demo member cannot create import runs');
reset role;

set local role anon;
select throws_ok($$ select * from public.import_runs $$, '42501', null, 'anon has no access to import runs');
reset role;

select * from finish();
rollback;
