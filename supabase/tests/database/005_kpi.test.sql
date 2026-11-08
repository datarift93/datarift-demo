-- KPI functions (F1): values on a hand-computed dataset, filters, previous period,
-- time series grain and empty buckets, time zone, and access.
begin;
create extension if not exists pgtap with schema extensions;

select plan(22);

-- Fixture -----------------------------------------------------------------------
-- Org K: 2 physical stores in different regions + online, 2 categories.
insert into public.orgs (id, slug, name) values
  ('40000000-0000-0000-0000-00000000000a', 'kpi-test', 'KPI test'),
  ('40000000-0000-0000-0000-00000000000b', 'kpi-other', 'KPI other');
insert into auth.users (id, email) values
  ('40000000-0000-0000-0000-0000000000a1', 'kpi-demo@test.local'),
  ('40000000-0000-0000-0000-0000000000b1', 'kpi-other@test.local');
insert into public.org_members (org_id, user_id, role) values
  ('40000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a1', 'demo'),
  ('40000000-0000-0000-0000-00000000000b', '40000000-0000-0000-0000-0000000000b1', 'admin');

do $$
declare
  k uuid := '40000000-0000-0000-0000-00000000000a';
  r14 bigint; r12 bigint; waw bigint; krk bigint; onl bigint; ca bigint; cb bigint; pa bigint; pb bigint;
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
  insert into public.categories (org_id, category_code, name) values (k, 'A', 'Kategoria A') returning id into ca;
  insert into public.categories (org_id, category_code, name) values (k, 'B', 'Kategoria B') returning id into cb;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'PA', 'A', ca, 10, 'PLN') returning id into pa;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'PB', 'B', cb, 20, 'PLN') returning id into pb;

  -- O1 WAW 10.03: 2 x PA (10, cost 6) + 1 x PB (20, cost 15) -> revenue 40, margin 13
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O1', waw, '2025-03-10T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values
    (k, o, 1, pa, 2, 10, 6), (k, o, 2, pb, 1, 20, 15);
  -- O2 KRK 11.03: 1 x PA -> 10 / 4
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O2', krk, '2025-03-11T10:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, pa, 1, 10, 6);
  -- O3 ONLINE 11.03 23:30 local: 3 x PB -> 60 / 15
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O3', onl, '2025-03-11T23:30:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, pb, 3, 20, 15);
  -- O4 WAW 03.03 (previous period): 1 x PA -> 10 / 4
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O4', waw, '2025-03-03T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, pa, 1, 10, 6);
  -- O5 ONLINE 16.03 23:30 UTC = 17.03 00:30 in Warsaw: outside 10-16.03. 1 x PA at 5 (cost 3)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'O5', onl, '2025-03-16T23:30:00Z') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, pa, 1, 5, 3);
end $$;

select private.refresh_analytics();

create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

select pg_temp.login_as('40000000-0000-0000-0000-0000000000a1');

-- Summary -----------------------------------------------------------------------
select results_eq(
  $$ select period, date_from, date_to, revenue, margin, orders, units, first_day
     from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  $$ values ('current'::text,  '2025-03-10'::date, '2025-03-16'::date, 110.00::numeric, 32.00::numeric, 3::bigint, 7::bigint, '2025-03-03'::date),
            ('previous'::text, '2025-03-03'::date, '2025-03-09'::date,  10.00::numeric,  4.00::numeric, 1::bigint, 1::bigint, '2025-03-03'::date) $$,
  'all stores: current and previous 7-day periods; 00:30 local on 17.03 is excluded');

select results_eq(
  $$ select revenue, margin, orders, units from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'A') where period = 'current' $$,
  $$ values (30.00::numeric, 12.00::numeric, 2::bigint, 3::bigint) $$,
  'category A: only A lines, orders = orders containing A (O1, O2)');

select results_eq(
  $$ select revenue, orders from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'B') where period = 'current' $$,
  $$ values (80.00::numeric, 2::bigint) $$,
  'category B: O1 counted for both categories, never double-counted in the total');

select results_eq(
  $$ select revenue, orders from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online') where period = 'current' $$,
  $$ values (60.00::numeric, 1::bigint) $$,
  'channel online');

select results_eq(
  $$ select revenue, orders from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'store') where period = 'current' $$,
  $$ values (50.00::numeric, 2::bigint) $$,
  'channel store');

select results_eq(
  $$ select revenue from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, '14') where period = 'current' $$,
  $$ values (40.00::numeric) $$,
  'region 14 (only WAW-01; online has no region)');

select results_eq(
  $$ select revenue, orders from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'store', '12', 'A') where period = 'current' $$,
  $$ values (10.00::numeric, 1::bigint) $$,
  'combined filters: store + region 12 + category A');

select results_eq(
  $$ select revenue, orders from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', 'online', null, 'A') where period = 'current' $$,
  $$ values (0::numeric, 0::bigint) $$,
  'no data for the filters: zeros, not an error');

select is(
  (select revenue from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-17', '2025-03-17', 'online') where period = 'current'),
  5.00::numeric,
  'the 23:30 UTC order counts on 17.03 (Warsaw day)');

-- Time series -------------------------------------------------------------------
select results_eq(
  $$ select grain, bucket, revenue from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  $$ values ('day'::text, '2025-03-10'::date, 40.00::numeric), ('day', '2025-03-11', 70.00),
            ('day', '2025-03-12', 0), ('day', '2025-03-13', 0), ('day', '2025-03-14', 0),
            ('day', '2025-03-15', 0), ('day', '2025-03-16', 0) $$,
  'daily grain for a week, empty days filled with 0');

select is(
  (select array_agg(distinct grain) from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-01-01', '2025-06-30')),
  array['week'],
  '181 days -> weekly grain');

select results_eq(
  $$ select bucket from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-01-01', '2025-06-30') limit 2 $$,
  $$ values ('2025-01-01'::date), ('2025-01-06'::date) $$,
  'first week bucket is clipped to the period start, then ISO Mondays');

select is(
  (select sum(revenue) from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-01-01', '2025-06-30')),
  125.00::numeric,
  'weekly buckets add up to the total');

select is(
  (select array_agg(distinct grain) from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2024-01-01', '2025-12-31')),
  array['month'],
  'two years -> monthly grain');

select is(
  (select count(*)::int from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2024-01-01', '2025-12-31')),
  24,
  'monthly buckets cover every month, even empty ones');

select is(
  (select sum(revenue) from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'B')),
  80.00::numeric,
  'time series respects the category filter');

-- Errors and access ---------------------------------------------------------------
select throws_ok(
  $$ select * from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-16', '2025-03-10') $$,
  '22023', 'niepoprawny okres', 'reversed period is rejected');

select throws_ok(
  $$ select * from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16', null, null, 'XYZ') $$,
  '22023', 'nieznana kategoria: XYZ', 'unknown category is rejected');

select throws_ok(
  $$ select * from analytics.sales_store_day $$,
  '42501', null, 'materialized views are not readable directly (no RLS on them)');
reset role;

select pg_temp.login_as('40000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select * from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no KPIs');
select throws_ok(
  $$ select * from public.kpi_timeseries('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no time series');
reset role;

set local role anon;
select throws_ok(
  $$ select * from public.kpi_summary('40000000-0000-0000-0000-00000000000a', '2025-03-10', '2025-03-16') $$,
  '42501', null, 'anon cannot call KPI functions');
reset role;

select * from finish();
rollback;
