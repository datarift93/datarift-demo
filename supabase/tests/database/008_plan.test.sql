-- Plan vs actual (F6): values on a hand-computed dataset at store, region and network
-- level, full months only, filters, plan 0, time zone, and access.
begin;
create extension if not exists pgtap with schema extensions;

select plan(17);

-- Fixture -----------------------------------------------------------------------
-- Org P: WAW-01 (region 14), KRK-01 (region 12), ONLINE (no region). Months in 2030,
-- outside the real data, so the test also passes on a database with the full dataset.
--
--            plan Jan  actual Jan   plan Feb  actual Feb   plan Mar  actual Mar
--   WAW-01     1000        900        1000       1100        1000        300
--   KRK-01      500        600         500          0           -          -
--   ONLINE     2000       1500           0         50           -          -
-- ONLINE's February sale is at 23:30 UTC on 31.01 = 00:30 on 01.02 in Warsaw.
insert into public.orgs (id, slug, name) values
  ('80000000-0000-0000-0000-00000000000a', 'plan-test', 'Plan test'),
  ('80000000-0000-0000-0000-00000000000b', 'plan-other', 'Plan other');
insert into auth.users (id, email) values
  ('80000000-0000-0000-0000-0000000000a1', 'plan-demo@test.local'),
  ('80000000-0000-0000-0000-0000000000b1', 'plan-other@test.local');
insert into public.org_members (org_id, user_id, role) values
  ('80000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-0000000000a1', 'demo'),
  ('80000000-0000-0000-0000-00000000000b', '80000000-0000-0000-0000-0000000000b1', 'admin');

do $$
declare
  k uuid := '80000000-0000-0000-0000-00000000000a';
  r14 bigint; r12 bigint; waw bigint; krk bigint; onl bigint; c bigint; p bigint; o bigint;
begin
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '14', 'mazowieckie', 1.2) returning id into r14;
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '12', 'małopolskie', 1.0) returning id into r12;
  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    values (k, 'WAW-01', 'Warszawa 1', 'store', 'Warszawa', r14, 500, '2020-01-01') returning id into waw;
  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    values (k, 'KRK-01', 'Kraków 1', 'store', 'Kraków', r12, 400, '2020-01-01') returning id into krk;
  insert into public.stores (org_id, store_code, name, channel, opened_on)
    values (k, 'ONLINE', 'Sklep internetowy', 'online', '2020-01-01') returning id into onl;
  insert into public.categories (org_id, category_code, name) values (k, 'A', 'Kategoria A') returning id into c;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (k, 'PA', 'A', c, 100, 'PLN') returning id into p;

  insert into public.budgets (org_id, store_id, month, revenue_plan) values
    (k, waw, '2030-01-01', 1000), (k, waw, '2030-02-01', 1000), (k, waw, '2030-03-01', 1000),
    (k, krk, '2030-01-01', 500),  (k, krk, '2030-02-01', 500),
    (k, onl, '2030-01-01', 2000), (k, onl, '2030-02-01', 0);

  -- (order code, store, local time, quantity, unit price)
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P1', waw, '2030-01-10T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 9, 100, 60);
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P2', waw, '2030-02-10T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 11, 100, 60);
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P3', waw, '2030-03-15T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 3, 100, 60);
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P4', krk, '2030-01-20T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 6, 100, 60);
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P5', onl, '2030-01-05T12:00:00+01:00') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 15, 100, 60);
  insert into public.orders (org_id, order_code, store_id, ordered_at) values (k, 'P6', onl, '2030-01-31T23:30:00Z') returning id into o;
  insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln) values (k, o, 1, p, 1, 50, 30);
end $$;

select private.refresh_analytics();

create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

select pg_temp.login_as('80000000-0000-0000-0000-0000000000a1');

-- Levels ------------------------------------------------------------------------
select results_eq(
  $$ select month, plan, actual, realization, deviation
     from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28')
     where level = 'network' $$,
  $$ values (null::date, 5000.00::numeric, 4150.00::numeric, 0.83::numeric, -850.00::numeric),
            ('2030-01-01', 3500.00, 3000.00, 3000.00 / 3500.00, -500.00),
            ('2030-02-01', 1500.00, 1150.00, 1150.00 / 1500.00, -350.00) $$,
  'network: period total first, then each full month');

select results_eq(
  $$ select store_code, store_name, region_code, region_name, month, plan, actual, realization, deviation
     from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28')
     where level = 'store' order by store_code, month nulls first $$,
  $$ values ('KRK-01'::text, 'Kraków 1'::text, '12'::text, 'małopolskie'::text, null::date, 1000.00::numeric, 600.00::numeric, 0.6::numeric, -400.00::numeric),
            ('KRK-01', 'Kraków 1', '12', 'małopolskie', '2030-01-01', 500.00, 600.00, 1.2, 100.00),
            ('KRK-01', 'Kraków 1', '12', 'małopolskie', '2030-02-01', 500.00, 0, 0, -500.00),
            ('ONLINE', 'Sklep internetowy', null, 'Sklep internetowy', null, 2000.00, 1550.00, 0.775, -450.00),
            ('ONLINE', 'Sklep internetowy', null, 'Sklep internetowy', '2030-01-01', 2000.00, 1500.00, 0.75, -500.00),
            ('ONLINE', 'Sklep internetowy', null, 'Sklep internetowy', '2030-02-01', 0.00, 50.00, null, 50.00),
            ('WAW-01', 'Warszawa 1', '14', 'mazowieckie', null, 2000.00, 2000.00, 1, 0.00),
            ('WAW-01', 'Warszawa 1', '14', 'mazowieckie', '2030-01-01', 1000.00, 900.00, 0.9, -100.00),
            ('WAW-01', 'Warszawa 1', '14', 'mazowieckie', '2030-02-01', 1000.00, 1100.00, 1.1, 100.00) $$,
  'store: every store-month, a sale without sales is 0, plan 0 gives null realization, local day');

select results_eq(
  $$ select store_code, region_code, region_name, plan, actual
     from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28')
     where level = 'region' and month is null order by region_name $$,
  $$ values (null::text, '12'::text, 'małopolskie'::text, 1000.00::numeric, 600.00::numeric),
            (null, '14', 'mazowieckie', 2000.00, 2000.00),
            (null, null, 'Sklep internetowy', 2000.00, 1550.00) $$,
  'region: one group per region, the online store as its own group');

select is(
  (select count(*)::int from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28') where level = 'region'),
  9,
  'region: 3 groups x (2 months + total)');

-- Full months only ----------------------------------------------------------------
select results_eq(
  $$ select month, plan, actual from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-15', '2030-03-31')
     where level = 'network' $$,
  $$ values (null::date, 2500.00::numeric, 1450.00::numeric),
            ('2030-02-01', 1500.00, 1150.00),
            ('2030-03-01', 1000.00, 300.00) $$,
  'a period starting mid-January covers February and March only');

select results_eq(
  $$ select month, plan, actual from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-27')
     where level = 'network' $$,
  $$ values (null::date, 3500.00::numeric, 3000.00::numeric), ('2030-01-01', 3500.00, 3000.00) $$,
  'a period ending a day before the end of February drops February');

select is(
  (select count(*)::int from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-02', '2030-02-27')),
  0,
  'no full month in the period: no rows (not even a network total)');

select is(
  (select count(*)::int from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-02-01', '2030-02-28') where month is not null),
  7,
  'exactly one month (February, not a leap year): 3 stores + 3 region groups + network');

-- Filters -------------------------------------------------------------------------
select results_eq(
  $$ select level, store_code, plan, actual from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28', 'online')
     where month is null $$,
  $$ values ('network'::text, null::text, 2000.00::numeric, 1550.00::numeric),
            ('region', null, 2000.00, 1550.00),
            ('store', 'ONLINE', 2000.00, 1550.00) $$,
  'channel online: only the online store');

select results_eq(
  $$ select level, store_code, plan, actual from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28', 'store', '12')
     where month is null $$,
  $$ values ('network'::text, null::text, 1000.00::numeric, 600.00::numeric),
            ('region', null, 1000.00, 600.00),
            ('store', 'KRK-01', 1000.00, 600.00) $$,
  'channel store + region 12: only KRK-01');

select is(
  (select plan from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28', 'store') where level = 'network' and month is null),
  3000.00::numeric,
  'channel store: both physical stores');

select results_eq(
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28', null, null, 'A') $$,
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28') $$,
  'the category filter is ignored (budgets are per store, not per category)');

select is(
  (select count(*)::int from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28', 'online', '14')),
  0,
  'no store matches the filters: no rows');

-- Errors and access ---------------------------------------------------------------
select throws_ok(
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-02-28', '2030-01-01') $$,
  '22023', 'niepoprawny okres', 'reversed period is rejected');

select throws_ok(
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', null, '2030-01-01') $$,
  '22023', 'niepoprawny okres', 'missing period start is rejected');
reset role;

select pg_temp.login_as('80000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no plan');
reset role;

set local role anon;
select throws_ok(
  $$ select * from public.plan_vs_actual('80000000-0000-0000-0000-00000000000a', '2030-01-01', '2030-02-28') $$,
  '42501', null, 'anon cannot call plan_vs_actual');
reset role;

select * from finish();
rollback;
