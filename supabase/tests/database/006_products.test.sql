-- Product functions (F2): ranking and ABC classes on a hand-computed dataset, the class
-- boundaries (exactly 80% / 95% before a product), ties, zero revenue, filters, time zone
-- and access.
begin;
create extension if not exists pgtap with schema extensions;

select plan(22);

-- Fixture -----------------------------------------------------------------------
-- Org P: 2 physical stores in different regions + online, 2 categories, 8 products.
-- In 10-16.03.2025 total revenue is exactly 1000, so every share is a short decimal:
--   rank sku cat rev  cum   share before -> class
--   1    P1  X   500  0.50  0.00 -> A
--   2    P2  X   300  0.80  0.50 -> A
--   3    P3  Y   100  0.90  0.80 -> B  (exactly 80% before: not < 0.80)
--   4    P4  Y    50  0.95  0.90 -> B
--   5    P5  X    25  0.975 0.95 -> C  (exactly 95% before; tie with P6, sku decides)
--   6    P6  Y    25  1.00  0.975-> C
--   7    P7  Y     0  1.00  1.00 -> C  (revenue 0: margin_pct null)
--   P8 has no sales and is not listed.
insert into public.orgs (id, slug, name) values
  ('60000000-0000-0000-0000-00000000000a', 'products-test', 'Products test'),
  ('60000000-0000-0000-0000-00000000000b', 'products-other', 'Products other');
insert into auth.users (id, email) values
  ('60000000-0000-0000-0000-0000000000a1', 'products-demo@test.local'),
  ('60000000-0000-0000-0000-0000000000b1', 'products-other@test.local');
insert into public.org_members (org_id, user_id, role) values
  ('60000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000a1', 'demo'),
  ('60000000-0000-0000-0000-00000000000b', '60000000-0000-0000-0000-0000000000b1', 'admin');

do $$
declare
  k uuid := '60000000-0000-0000-0000-00000000000a';
  r14 bigint; r12 bigint; waw bigint; krk bigint; onl bigint; cx bigint; cy bigint;
  p1 bigint; p2 bigint; p3 bigint; p4 bigint; p5 bigint; p6 bigint; p7 bigint;
  o bigint;
begin
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '14', 'mazowieckie', 1.2) returning id into r14;
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '12', 'małopolskie', 1.0) returning id into r12;
  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    values (k, 'WAW-01', 'Warszawa 1', 'store', 'Warszawa', r14, 500, '2020-01-01') returning id into waw;
  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    values (k, 'KRK-01', 'Kraków 1', 'store', 'Kraków', r12, 400, '2020-01-01') returning id into krk;
  insert into public.stores (org_id, store_code, name, channel, opened_on)
    values (k, 'ONLINE', 'Sklep internetowy', 'online', '2020-01-01') returning id into onl;
  insert into public.categories (org_id, category_code, name) values (k, 'X', 'Kategoria X') returning id into cx;
  insert into public.categories (org_id, category_code, name) values (k, 'Y', 'Kategoria Y') returning id into cy;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P1', 'Produkt 1', cx, 100, 'EUR') returning id into p1;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P2', 'Produkt 2', cx, 100, 'PLN') returning id into p2;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P3', 'Produkt 3', cy, 100, 'PLN') returning id into p3;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P4', 'Produkt 4', cy, 25, 'PLN') returning id into p4;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P5', 'Produkt 5', cx, 25, 'PLN') returning id into p5;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P6', 'Produkt 6', cy, 25, 'PLN') returning id into p6;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P7', 'Produkt 7', cy, 10, 'PLN') returning id into p7;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'P8', 'Produkt 8', cy, 10, 'PLN');

  -- O1 WAW 10.03: 3 x P1 @100 (cost 60) + 1 x P3 @100 (cost 70)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O1', waw, '2025-03-10T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values
    (k, o, 1, p1, 3, 100, 60), (k, o, 2, p3, 1, 100, 70);
  -- O2 KRK 11.03: 3 x P2 @100 (cost 80)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O2', krk, '2025-03-11T10:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p2, 3, 100, 80);
  -- O3 ONLINE 12.03: 2 x P4 @25 (cost 20) + 1 x P5 @25 (cost 10)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O3', onl, '2025-03-12T09:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values
    (k, o, 1, p4, 2, 25, 20), (k, o, 2, p5, 1, 25, 10);
  -- O4 ONLINE 16.03 23:30 UTC = 17.03 00:30 in Warsaw: outside 10-16.03. 1 x P6 @99
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O4', onl, '2025-03-16T23:30:00Z') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p6, 1, 99, 50);
  -- O5 WAW 13.03: 1 x P6 @25 (cost 25)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O5', waw, '2025-03-13T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p6, 1, 25, 25);
  -- O6 KRK 14.03: 2 x P1 @100 (cost 60) -> P1 is in 2 orders
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O6', krk, '2025-03-14T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p1, 2, 100, 60);
  -- O7 WAW 15.03: 1 x P7 given away @0 (cost 5)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O7', waw, '2025-03-15T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p7, 1, 0, 5);
end $$;

-- Not private.refresh_analytics(): while Stage 6 sessions share a database its body may
-- come from another session's migration.
refresh materialized view analytics.sales_product_store_day;

create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

select pg_temp.login_as('60000000-0000-0000-0000-0000000000a1');

-- Ranking -----------------------------------------------------------------------
select results_eq(
  $$ select rank, sku, revenue, margin, margin_pct, units, orders, revenue_share, cum_share, abc_class
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  $$ values (1::bigint, 'P1'::text, 500.00::numeric, 200.00::numeric, 0.4::numeric, 5::bigint, 2::bigint, 0.5::numeric, 0.5::numeric, 'A'::text),
            (2, 'P2', 300.00,  60.00, 0.2, 3, 1, 0.3,   0.8,   'A'),
            (3, 'P3', 100.00,  30.00, 0.3, 1, 1, 0.1,   0.9,   'B'),
            (4, 'P4',  50.00,  10.00, 0.2, 2, 1, 0.05,  0.95,  'B'),
            (5, 'P5',  25.00,  15.00, 0.6, 1, 1, 0.025, 0.975, 'C'),
            (6, 'P6',  25.00,   0.00, 0,   1, 1, 0.025, 1,     'C'),
            (7, 'P7',   0.00,  -5.00, null, 1, 1, 0,    1,     'C') $$,
  'ranking: ABC order, boundaries at exactly 80%/95% before, sku breaks the P5/P6 tie, revenue 0 -> margin_pct null, 17.03 00:30 local excluded');

select results_eq(
  $$ select category_code, category_name, purchase_currency::text, product_name
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') where sku in ('P1', 'P2') $$,
  $$ values ('X'::text, 'Kategoria X'::text, 'EUR'::text, 'Produkt 1'::text), ('X', 'Kategoria X', 'PLN', 'Produkt 2') $$,
  'ranking carries product name, category and purchase currency');

select is(
  (select count(*)::int from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') where sku = 'P8'),
  0,
  'products without sales in the period are not listed');

select results_eq(
  $$ select sku, revenue, round(cum_share, 6), abc_class
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online') $$,
  $$ values ('P4'::text, 50.00::numeric, 0.666667::numeric, 'A'::text), ('P5', 25.00, 1, 'A') $$,
  'channel online: shares are within the filtered total');

select results_eq(
  $$ select sku, revenue, units, orders, abc_class
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, '12') $$,
  $$ values ('P2'::text, 300.00::numeric, 3::bigint, 1::bigint, 'A'::text), ('P1', 200.00, 2, 1, 'A') $$,
  'region 12 (only KRK-01): P1 counts only its KRK order');

select results_eq(
  $$ select sku, abc_class
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'Y') $$,
  $$ values ('P3'::text, 'A'::text), ('P4', 'A'), ('P6', 'B'), ('P7', 'C') $$,
  'category Y: classes recomputed within the category (before: 0, 0.57, 0.86, 1)');

select results_eq(
  $$ select sku, revenue, cum_share, abc_class
     from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'store', '14', 'X') $$,
  $$ values ('P1'::text, 300.00::numeric, 1::numeric, 'A'::text) $$,
  'combined filters: store + region 14 + category X');

select is(
  (select count(*)::int from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online', '14')),
  0,
  'no data for the filters: empty ranking, not an error');

select results_eq(
  $$ select sku, revenue from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-17', '2025-03-17') $$,
  $$ values ('P6'::text, 99.00::numeric) $$,
  'the 23:30 UTC order counts on 17.03 (Warsaw day)');

-- ABC summary -------------------------------------------------------------------
select results_eq(
  $$ select abc_class, products, revenue, revenue_share, round(product_share, 6)
     from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  $$ values ('A'::text, 2::bigint, 800.00::numeric, 0.8::numeric, round(2 / 7.0, 6)),
            ('B', 2, 150.00, 0.15, round(2 / 7.0, 6)),
            ('C', 3,  50.00, 0.05, round(3 / 7.0, 6)) $$,
  'summary: products, revenue and shares per class');

select results_eq(
  $$ select round(sum(revenue_share), 12), round(sum(product_share), 12), sum(products)
     from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'Y') $$,
  $$ values (1::numeric, 1::numeric, 4::numeric) $$,
  'shares of the classes add up to 100% (category Y, non-terminating fractions)');

select results_eq(
  $$ select abc_class, products, revenue
     from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online') $$,
  $$ values ('A'::text, 2::bigint, 75.00::numeric), ('B', 0, 0), ('C', 0, 0) $$,
  'summary always has three rows; empty classes are 0');

select results_eq(
  $$ select abc_class, products, revenue, revenue_share, product_share
     from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online', '14') $$,
  $$ values ('A'::text, 0::bigint, 0::numeric, null::numeric, null::numeric), ('B', 0, 0, null, null), ('C', 0, 0, null, null) $$,
  'no data: three rows of zeros, shares null');

select is(
  (select sum(revenue) from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16')),
  (select sum(revenue) from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16')),
  'summary revenue equals ranking revenue');

-- Errors and access ---------------------------------------------------------------
select throws_ok(
  $$ select * from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-16', '2025-03-10') $$,
  '22023', 'niepoprawny okres', 'reversed period is rejected');

select throws_ok(
  $$ select * from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', null, '2025-03-10') $$,
  '22023', 'niepoprawny okres', 'missing period is rejected (summary)');

select throws_ok(
  $$ select * from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'XYZ') $$,
  '22023', 'nieznana kategoria: XYZ', 'unknown category is rejected');

select throws_ok(
  $$ select * from analytics.sales_product_store_day $$,
  '42501', null, 'the materialized view is not readable directly (no RLS on it)');
reset role;

select pg_temp.login_as('60000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select * from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no ranking');
select throws_ok(
  $$ select * from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no ABC summary');
reset role;

set local role anon;
select throws_ok(
  $$ select * from public.product_ranking('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', null, 'anon cannot call product_ranking');
select throws_ok(
  $$ select * from public.product_abc_summary('60000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', null, 'anon cannot call product_abc_summary');
reset role;

select * from finish();
rollback;
