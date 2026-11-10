-- Customer functions (F3): RFM scores and segments on a hand-computed dataset, filters
-- (channel = order's store, region = customer's), time zone, cohorts, and access.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- Fixture -----------------------------------------------------------------------
-- Org C: one physical store (region 14) + online, seven customers, all dates in 2022-2023
-- (before the real dataset). Every order has one line of quantity 1, so revenue = price.
--
--   code region orders (Warsaw day, channel, PLN)                    p_to = 2023-12-31
--   C1   14     2023-06-01 S 100, 10-05 S 100, 11-10 O 100, 12-20 S 100,
--               + 2023-12-31 23:30 UTC = 2024-01-01 00:30 local, O 100 (after p_to)
--   C2   14     2023-12-30 O 50
--   C3   12     2022-11-15 S 300 (outside the window), 2023-03-01/04-01/05-01 S 200
--   C4   12     2022-06-01 O 80 (outside the window)
--   C5   14     2023-09-15 S 70, 2023-09-20 S 70
--   C6   12     2023-09-01 S 30, 2023-11-05 O 30
--   C7   14     2022-11-26 S 40 (400 days before p_to), 2023-12-28 S 40: returning, not new
--   + one anonymous store order (no customer) on 2023-12-10.
--
-- At p_to = 2023-12-31 (window 2023-01-01..2023-12-31; ntile(5) over 7 customers gives
-- bands of 2, 2, 1, 1, 1; ties by customer_code):
--   code  R days  F  M    all orders  R  F  M  segment
--   C1    11      4  400  4           3  5  4  Lojalni (F >= 4; R 3, so not Mistrzowie)
--   C2    1       1  50   1           5  1  2  Nowi (R >= 4, first and only order)
--   C3    244     3  600  4           1  4  5  Lojalni
--   C4    578     0  0    1           1  1  1  Utraceni
--   C5    102     2  140  2           2  2  3  Zagrożeni odejściem
--   C6    56      2  60   2           2  3  2  Zagrożeni odejściem
--   C7    3       1  40   2           4  2  1  Obiecujący (R >= 4 but 2 orders in history)
-- Store channel only (C1, C3, C5, C6, C7: one per band): C1 R4 F4 Mistrzowie, C3 Lojalni,
-- C7 R5 with 2 store orders -> Obiecujący, C5 Obiecujący, C6 Zagrożeni odejściem.
insert into public.orgs (id, slug, name) values
  ('70000000-0000-0000-0000-00000000000a', 'customers-test', 'Customers test'),
  ('70000000-0000-0000-0000-00000000000b', 'customers-other', 'Customers other');
insert into auth.users (id, email) values
  ('70000000-0000-0000-0000-0000000000a1', 'customers-demo@test.local'),
  ('70000000-0000-0000-0000-0000000000b1', 'customers-other@test.local');
insert into public.org_members (org_id, user_id, role) values
  ('70000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-0000000000a1', 'demo'),
  ('70000000-0000-0000-0000-00000000000b', '70000000-0000-0000-0000-0000000000b1', 'admin');

do $$
declare
  k uuid := '70000000-0000-0000-0000-00000000000a';
  r14 bigint; r12 bigint; waw bigint; onl bigint; cat bigint; pr bigint;
  c bigint; o bigint; n integer := 0;
  rec record;
begin
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '14', 'mazowieckie', 1.2) returning id into r14;
  insert into public.regions (org_id, region_code, name, purchasing_power_index) values (k, '12', 'małopolskie', 1.0) returning id into r12;
  insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    values (k, 'WAW-01', 'Warszawa 1', 'store', 'Warszawa', r14, 500, '2020-01-01') returning id into waw;
  insert into public.stores (org_id, store_code, name, channel, opened_on)
    values (k, 'ONLINE', 'Sklep internetowy', 'online', '2020-01-01') returning id into onl;
  insert into public.categories (org_id, category_code, name) values (k, 'A', 'Kategoria A') returning id into cat;
  insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency)
    values (k, 'P1', 'Produkt', cat, 10, 'PLN') returning id into pr;

  for rec in
    select * from (values
      ('C1', '14', '2023-06-01T12:00:00+02:00'::timestamptz, 'S', 100),
      ('C1', '14', '2023-10-05T12:00:00+02:00', 'S', 100),
      ('C1', '14', '2023-11-10T12:00:00+01:00', 'O', 100),
      ('C1', '14', '2023-12-20T12:00:00+01:00', 'S', 100),
      ('C1', '14', '2023-12-31T23:30:00Z', 'O', 100),
      ('C2', '14', '2023-12-30T12:00:00+01:00', 'O', 50),
      ('C3', '12', '2022-11-15T12:00:00+01:00', 'S', 300),
      ('C3', '12', '2023-03-01T12:00:00+01:00', 'S', 200),
      ('C3', '12', '2023-04-01T12:00:00+02:00', 'S', 200),
      ('C3', '12', '2023-05-01T12:00:00+02:00', 'S', 200),
      ('C4', '12', '2022-06-01T12:00:00+02:00', 'O', 80),
      ('C5', '14', '2023-09-15T12:00:00+02:00', 'S', 70),
      ('C5', '14', '2023-09-20T12:00:00+02:00', 'S', 70),
      ('C6', '12', '2023-09-01T12:00:00+02:00', 'S', 30),
      ('C6', '12', '2023-11-05T12:00:00+01:00', 'O', 30),
      ('C7', '14', '2022-11-26T12:00:00+01:00', 'S', 40),
      ('C7', '14', '2023-12-28T12:00:00+01:00', 'S', 40),
      (null, null, '2023-12-10T12:00:00+01:00', 'S', 999)
    ) as t (code, region, at, channel, price)
  loop
    c := null;
    if rec.code is not null then
      select id into c from public.customers where org_id = k and customer_code = rec.code;
      if c is null then
        insert into public.customers (org_id, customer_code, region_id, registered_on)
          values (k, rec.code, case rec.region when '14' then r14 else r12 end, rec.at::date)
          returning id into c;
      end if;
    end if;
    n := n + 1;
    insert into public.orders (org_id, order_code, store_id, customer_id, ordered_at)
      values (k, 'O' || n, case rec.channel when 'S' then waw else onl end, c, rec.at)
      returning id into o;
    insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price, unit_cost_pln)
      values (k, o, 1, pr, 1, rec.price, 1);
  end loop;
end $$;

-- Refresh only this migration's view: private.refresh_analytics() is redefined by each
-- Stage 6 session until the coordinator merges them.
refresh materialized view analytics.customer_day;

create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

select pg_temp.login_as('70000000-0000-0000-0000-0000000000a1');

-- RFM segments ------------------------------------------------------------------
select results_eq(
  $$ select segment, customers, revenue, avg_recency_days, avg_frequency, round(share_revenue, 4)
     from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  $$ values ('Mistrzowie'::text,         0::bigint,    0::numeric, null::numeric, null::numeric, 0::numeric),
            ('Lojalni',                   2, 1000, 127.5, 3.5, 0.7752),
            ('Nowi',                      1,   50,     1,   1, 0.0388),
            ('Obiecujący',                1,   40,     3,   1, 0.0310),
            ('Zagrożeni odejściem',       2,  200,    79,   2, 0.1550),
            ('Utraceni',                  1,    0,   578,   0, 0) $$,
  'six segments in rule order (empty one included); revenue = window revenue; anonymous and post-p_to orders excluded');

select is(
  (select array_agg(round(share_customers, 4)) from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31')),
  array[0, 0.2857, 0.1429, 0.1429, 0.2857, 0.1429]::numeric[],
  'customer shares');

select results_eq(
  $$ select dimension, score, customers, min_value, max_value
     from public.customer_rfm_scores('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31')
     where score in (1, 5) $$,
  $$ values ('R'::text, 1, 2::bigint, 244::numeric, 578::numeric), ('R', 5, 1, 1, 1),
            ('F', 1, 2, 0, 1), ('F', 5, 1, 4, 4),
            ('M', 1, 2, 0, 40), ('M', 5, 1, 600, 600) $$,
  'score bands: R by recency (most recent = 5), F and M descending; lowest bands hold 2 of 7');

select is(
  (select count(*)::int from public.customer_rfm_scores('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31')),
  15, 'scores: 3 dimensions x 5 scores');

select results_eq(
  $$ select customers from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', 'online') $$,
  $$ values (0::bigint), (1), (1), (1), (0), (1) $$,
  'channel online: only online orders (C4 Utraceni, C6 Lojalni, C2 Nowi, C1 Obiecujący)');

select results_eq(
  $$ select customers from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', 'store') $$,
  $$ values (1::bigint), (1), (0), (2), (1), (0) $$,
  'returning customer: C7 is the most recent store buyer with 1 order in the window but 2 in history -> not Nowi');

select results_eq(
  $$ select customers from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', null, '12') $$,
  $$ values (0::bigint), (0), (0), (1), (1), (1) $$,
  'region = customer region 12 (C3, C4, C6), although C6 also bought online');

select results_eq(
  $$ select customers, revenue from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', null, '99') $$,
  $$ values (0::bigint, 0::numeric), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0) $$,
  'no customers for the filters: six empty rows, not an error');

select is(
  (select sum(customers)::int from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', null, null, 'XYZ')),
  7, 'category filter is ignored');

select is(
  (select sum(customers)::int from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-12-01', '2023-12-31')),
  7, 'p_from does not limit customers: RFM is as of p_to over all history');

select results_eq(
  $$ select avg_recency_days, avg_frequency, revenue from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2024-01-01')
     where segment = 'Mistrzowie' $$,
  $$ values (0::numeric, 5::numeric, 500::numeric) $$,
  '23:30 UTC on 31.12 is 01.01 in Warsaw: counted only from p_to = 2024-01-01');

select is(
  (select sum(customers)::int from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2022-01-01', '2022-12-31')),
  3, 'only customers with an order on or before p_to (C3, C4, C7)');

-- Cohorts -------------------------------------------------------------------------
-- Data ends 2024-01-01 (local) -> last full month = 2023-12.
select results_eq(
  $$ select cohort_month, months_since, cohort_size, active_customers, retention
     from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  $$ values ('2023-06-01'::date, 0, 1::bigint, 1::bigint, 1::numeric),
            ('2023-06-01', 1, 1, 0, 0), ('2023-06-01', 2, 1, 0, 0), ('2023-06-01', 3, 1, 0, 0),
            ('2023-06-01', 4, 1, 1, 1), ('2023-06-01', 5, 1, 1, 1), ('2023-06-01', 6, 1, 1, 1),
            ('2023-09-01', 0, 2, 2, 1), ('2023-09-01', 1, 2, 0, 0), ('2023-09-01', 2, 2, 1, 0.5),
            ('2023-09-01', 3, 2, 0, 0),
            ('2023-12-01', 0, 1, 1, 1) $$,
  'cohorts by first-order month in the period; complete triangle up to the last full month');

select is(
  (select count(*)::int from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31')
   where months_since = 0 and retention <> 1),
  0, 'month 0 = 100%');

select results_eq(
  $$ select cohort_month, months_since, cohort_size, active_customers
     from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', 'online') $$,
  $$ values ('2023-11-01'::date, 0, 2::bigint, 2::bigint), ('2023-11-01', 1, 2, 0),
            ('2023-12-01', 0, 1, 1) $$,
  'channel online: first ONLINE order defines the cohort (C1, C6 in 11.2023; C2 in 12.2023)');

select results_eq(
  $$ select cohort_month, months_since, active_customers
     from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', null, '12') $$,
  $$ values ('2023-09-01'::date, 0, 1::bigint), ('2023-09-01', 1, 0), ('2023-09-01', 2, 1), ('2023-09-01', 3, 0) $$,
  'region 12: only C6 starts in 2023 (C3 and C4 started in 2022)');

select results_eq(
  $$ select cohort_month, cohort_size from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-09-02', '2023-09-30')
     where months_since = 0 $$,
  $$ values ('2023-09-01'::date, 1::bigint) $$,
  'first order day must be in [p_from, p_to]: C6 (01.09) is out, C5 (15.09) is in');

select is(
  (select count(*)::int from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2021-01-01', '2021-12-31')),
  0, 'no cohorts in the period: empty result');

select is(
  (select count(*)::int from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31', null, null, 'XYZ')),
  12, 'cohorts ignore the category filter');

-- Errors and access ---------------------------------------------------------------
select throws_ok(
  $$ select * from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-12-31', '2023-01-01') $$,
  '22023', 'niepoprawny okres', 'segments: reversed period is rejected');
select throws_ok(
  $$ select * from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', null, '2023-01-01') $$,
  '22023', 'niepoprawny okres', 'cohorts: missing period is rejected');
select throws_ok(
  $$ select * from analytics.customer_day $$,
  '42501', null, 'the materialized view is not readable directly');
select throws_ok(
  $$ select * from private.customer_rfm('70000000-0000-0000-0000-00000000000a', '2023-12-31', null, null) $$,
  '42501', null, 'the per-customer RFM function is not callable by clients');
reset role;

select pg_temp.login_as('70000000-0000-0000-0000-0000000000b1');
select throws_ok(
  $$ select * from public.customer_rfm_segments('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no segments');
select throws_ok(
  $$ select * from public.customer_rfm_scores('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no scores');
select throws_ok(
  $$ select * from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  '42501', 'brak dostępu do organizacji', 'a member of another org gets no cohorts');
reset role;

set local role anon;
select throws_ok(
  $$ select * from public.customer_cohorts('70000000-0000-0000-0000-00000000000a', '2023-01-01', '2023-12-31') $$,
  '42501', null, 'anon cannot call customer functions');
reset role;

select * from finish();
rollback;
