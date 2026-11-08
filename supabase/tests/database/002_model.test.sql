-- RLS and constraints for the Stage 2 model. Run with `supabase test db`.
-- Everything runs in a transaction that is rolled back at the end.
begin;
create extension if not exists pgtap with schema extensions;

-- 10 org-scoped tables x 14 checks + 1 cross-org check + 10 global-table checks
-- + 5 generated-column / constraint checks.
select plan(156);

-- Fixtures -------------------------------------------------------------------
-- Two orgs; admin + demo in org A, admin in org B. Each org-scoped table has one
-- row per org with a fixed id: 900001001 in org A, 900002001 in org B (identity values in
-- the tests stay far below that).
insert into public.orgs (id, slug, name) values
  ('10000000-0000-0000-0000-00000000000a', 'org-a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'org-b', 'Org B');

insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-0000000000a1', 'admin-a@test.local'),
  ('20000000-0000-0000-0000-0000000000a2', 'demo-a@test.local'),
  ('20000000-0000-0000-0000-0000000000b1', 'admin-b@test.local'),
  ('20000000-0000-0000-0000-0000000000ab', 'admin-both@test.local');

insert into public.org_members (org_id, user_id, role) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'admin'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a2', 'demo'),
  ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000b1', 'admin'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000ab', 'admin'),
  ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000ab', 'admin');

create function pg_temp.seed_org(org uuid, rid bigint, sfx text) returns void language plpgsql as $$
begin
  insert into public.regions (id, org_id, region_code, name, purchasing_power_index)
    overriding system value values (rid, org, '14', 'mazowieckie ' || sfx, 1.250);
  insert into public.stores (id, org_id, store_code, name, channel, city, region_id, size_m2, opened_on)
    overriding system value values (rid, org, 'WAW-01', 'Warszawa 1', 'store', 'Warszawa', rid, 800, '2020-03-01');
  insert into public.categories (id, org_id, category_code, name)
    overriding system value values (rid, org, 'HOME', 'Dom i ogród');
  insert into public.products (id, org_id, sku, name, category_id, list_price, purchase_currency)
    overriding system value values (rid, org, 'HOME-0001', 'Konewka', rid, 49.99, 'EUR');
  insert into public.customers (id, org_id, customer_code, region_id, registered_on)
    overriding system value values (rid, org, 'C000001', rid, '2023-02-01');
  insert into public.promotions (id, org_id, promo_code, name, starts_on, ends_on, category_id, product_id, discount_pct)
    overriding system value values (rid, org, 'BF-2025', 'Black Friday 2025', '2025-11-28', '2025-12-01', null, null, 0.2000);
  insert into public.orders (id, org_id, order_code, store_id, customer_id, ordered_at)
    overriding system value values (rid, org, 'O0000001', rid, rid, '2025-11-28T14:05:00+01:00');
  insert into public.order_lines (id, org_id, order_id, line_no, product_id, quantity, unit_price, promotion_id, unit_cost_pln)
    overriding system value values (rid, org, rid, 1, rid, 3, 10.00, rid, 6.50);
  insert into public.purchases (id, org_id, purchase_code, product_id, purchase_date, quantity, unit_cost, currency, fx_rate, unit_cost_pln)
    overriding system value values (rid, org, 'P0000001', rid, '2025-11-03', 100, 1.50, 'EUR', 4.2500, 6.38);
  insert into public.budgets (id, org_id, store_id, month, revenue_plan)
    overriding system value values (rid, org, rid, '2025-11-01', 150000.00);
end $$;

select pg_temp.seed_org('10000000-0000-0000-0000-00000000000a', 900001001, 'A');
select pg_temp.seed_org('10000000-0000-0000-0000-00000000000b', 900002001, 'B');

insert into public.fx_rates (rate_date, mid_rate, table_no)
  values ('1999-11-03', 4.2500, '212/A/NBP/1999'); -- outside real NBP data, so the test runs on a loaded database too

-- Per table: a valid insert template. %1$L = org_id, %2$s = id of the referenced
-- fixture rows in that org (900001001 or 900002001).
create function pg_temp.cases() returns table (tbl text, insert_tpl text) language sql as $$
  values
    ('regions',     $q$insert into public.regions (org_id, region_code, name, purchasing_power_index) values (%1$L, '99', 'nowe', 1.000)$q$),
    ('stores',      $q$insert into public.stores (org_id, store_code, name, channel, city, region_id, size_m2, opened_on) values (%1$L, 'NEW-01', 'Nowy', 'store', 'Kraków', %2$s, 500, '2023-01-01')$q$),
    ('categories',  $q$insert into public.categories (org_id, category_code, name) values (%1$L, 'NEW', 'Nowa')$q$),
    ('products',    $q$insert into public.products (org_id, sku, name, category_id, list_price, purchase_currency) values (%1$L, 'NEW-0001', 'Nowy', %2$s, 10.00, 'PLN')$q$),
    ('customers',   $q$insert into public.customers (org_id, customer_code, region_id, registered_on) values (%1$L, 'CNEW', %2$s, '2023-01-01')$q$),
    ('promotions',  $q$insert into public.promotions (org_id, promo_code, name, starts_on, ends_on, discount_pct) values (%1$L, 'NEW', 'Nowa', '2025-01-01', '2025-01-31', 0.10)$q$),
    ('orders',      $q$insert into public.orders (org_id, order_code, store_id, ordered_at) values (%1$L, 'ONEW', %2$s, '2025-01-02T10:00:00+01:00')$q$),
    ('order_lines', $q$insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price) values (%1$L, %2$s, 99, %2$s, 1, 10.00)$q$),
    ('purchases',   $q$insert into public.purchases (org_id, purchase_code, product_id, purchase_date, quantity, unit_cost, currency) values (%1$L, 'PNEW', %2$s, '2025-01-02', 1, 5.00, 'PLN')$q$),
    ('budgets',     $q$insert into public.budgets (org_id, store_id, month, revenue_plan) values (%1$L, %2$s, '2030-01-01', 1000.00)$q$)
$$;

create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

-- Demo member of org A: reads own org only, cannot write anything (4 checks per table).
create function pg_temp.demo_checks() returns setof text language plpgsql as $$
declare
  c record;
  org_a constant uuid := '10000000-0000-0000-0000-00000000000a';
begin
  for c in select * from pg_temp.cases() loop
    return next results_eq(
      format('select id, org_id from public.%I', c.tbl),
      format('values (900001001::bigint, %L::uuid)', org_a),
      format('demo reads only own org rows in %s', c.tbl));
    return next throws_ok(
      format(c.insert_tpl, org_a, 900001001),
      '42501', null,
      format('demo cannot insert into %s', c.tbl));
    return next is_empty(
      format('update public.%I set org_id = org_id where id = 900001001 returning id', c.tbl),
      format('demo cannot update %s', c.tbl));
    return next is_empty(
      format('delete from public.%I where id = 900001001 returning id', c.tbl),
      format('demo cannot delete from %s', c.tbl));
  end loop;
end $$;

-- Admin of org A: writes own org, cannot touch org B (7 checks per table).
create function pg_temp.admin_checks() returns setof text language plpgsql as $$
declare
  c record;
  org_a constant uuid := '10000000-0000-0000-0000-00000000000a';
  org_b constant uuid := '10000000-0000-0000-0000-00000000000b';
begin
  for c in select * from pg_temp.cases() loop
    return next lives_ok(
      format(c.insert_tpl, org_a, 900001001),
      format('admin inserts into own org in %s', c.tbl));
    return next throws_ok(
      format(c.insert_tpl, org_b, 900002001),
      '42501', null,
      format('admin cannot insert into another org in %s', c.tbl));
    return next results_eq(
      format('update public.%I set org_id = org_id where id = 900001001 returning id', c.tbl),
      $v$ values (900001001::bigint) $v$,
      format('admin updates own org rows in %s', c.tbl));
    return next is_empty(
      format('update public.%I set org_id = org_id where id = 900002001 returning id', c.tbl),
      format('admin cannot update another org in %s', c.tbl));
    return next throws_ok(
      format('update public.%I set org_id = %L where id = 900001001', c.tbl, org_b),
      '23514', null,
      format('admin cannot move rows of %s to another org', c.tbl));
    return next is_empty(
      format('delete from public.%I where id = 900002001 returning id', c.tbl),
      format('admin cannot delete from another org in %s', c.tbl));
    return next results_eq(
      format('delete from public.%I where org_id = %L and id <> 900001001 returning org_id', c.tbl, org_a),
      format('values (%L::uuid)', org_a),
      format('admin deletes own org rows in %s', c.tbl));
  end loop;
end $$;

-- Admin of both orgs: RLS would allow the move, the trigger forbids it (1 check per table).
create function pg_temp.two_org_admin_checks() returns setof text language plpgsql as $$
declare
  c record;
begin
  for c in select * from pg_temp.cases() loop
    return next throws_ok(
      format('update public.%I set org_id = %L where id = 900001001', c.tbl, '10000000-0000-0000-0000-00000000000b'),
      '23514', format('org_id cannot be changed (table %s)', c.tbl),
      format('admin of both orgs cannot move rows of %s between orgs', c.tbl));
  end loop;
end $$;

-- anon and TRUNCATE (1 check per table each).
create function pg_temp.anon_checks() returns setof text language plpgsql as $$
declare
  c record;
begin
  for c in select * from pg_temp.cases() loop
    return next throws_ok(
      format('select * from public.%I', c.tbl),
      '42501', null,
      format('anon has no access to %s', c.tbl));
  end loop;
end $$;

create function pg_temp.truncate_checks() returns setof text language plpgsql as $$
declare
  c record;
begin
  for c in select * from pg_temp.cases() loop
    return next throws_ok(
      format('truncate public.%I cascade', c.tbl),
      '42501', null,
      format('authenticated cannot truncate %s (TRUNCATE bypasses RLS)', c.tbl));
  end loop;
end $$;

-- Org-scoped tables ----------------------------------------------------------

select pg_temp.login_as('20000000-0000-0000-0000-0000000000a2');
select * from pg_temp.demo_checks();
select * from pg_temp.truncate_checks();
reset role;

select pg_temp.login_as('20000000-0000-0000-0000-0000000000a1');
select * from pg_temp.admin_checks();
reset role;

select pg_temp.login_as('20000000-0000-0000-0000-0000000000ab');
select * from pg_temp.two_org_admin_checks();
reset role;

set local role anon;
select * from pg_temp.anon_checks();
reset role;

-- Rows of org B are untouched after all of the above (one per table, 10 tables).
select results_eq(
  $$ select count(*)::int from (
       select org_id from public.regions union all select org_id from public.stores
       union all select org_id from public.categories union all select org_id from public.products
       union all select org_id from public.customers union all select org_id from public.promotions
       union all select org_id from public.orders union all select org_id from public.order_lines
       union all select org_id from public.purchases union all select org_id from public.budgets
     ) t where org_id = '10000000-0000-0000-0000-00000000000b' $$,
  $$ values (10) $$,
  'org B rows survive demo and admin writes from org A'
);

-- Global reference tables ----------------------------------------------------

select pg_temp.login_as('20000000-0000-0000-0000-0000000000a2');
select results_eq($$ select mid_rate from public.fx_rates where rate_date = '1999-11-03' $$, $$ values (4.2500::numeric) $$,
  'authenticated reads fx_rates');
select isnt_empty($$ select * from public.calendar $$, 'authenticated reads calendar');
reset role;

-- Write attempts as an org admin (the most privileged app role).
select pg_temp.login_as('20000000-0000-0000-0000-0000000000a1');
select throws_ok($$ insert into public.fx_rates values ('2025-11-04', 4.3, '213/A/NBP/2025') $$,
  '42501', null, 'authenticated cannot insert into fx_rates');
select throws_ok($$ update public.fx_rates set mid_rate = 9 $$,
  '42501', null, 'authenticated cannot update fx_rates');
select throws_ok($$ delete from public.fx_rates $$,
  '42501', null, 'authenticated cannot delete from fx_rates');
select throws_ok($$ insert into public.calendar (date) values ('2030-01-01') $$,
  '42501', null, 'authenticated cannot insert into calendar');
select throws_ok($$ update public.calendar set is_holiday = true, holiday_name = 'x' $$,
  '42501', null, 'authenticated cannot update calendar');
reset role;

set local role anon;
select throws_ok($$ select * from public.fx_rates $$, '42501', null, 'anon has no access to fx_rates');
select throws_ok($$ select * from public.calendar $$, '42501', null, 'anon has no access to calendar');
reset role;

select is(
  has_table_privilege('anon', 'public.calendar', 'select'),
  false,
  'anon has no select privilege on calendar'
);

-- Generated columns ----------------------------------------------------------

select results_eq(
  $$ select line_revenue, line_margin from public.order_lines where id = 900001001 $$,
  $$ values (30.00::numeric, 10.50::numeric) $$,
  'line_revenue = quantity * unit_price, line_margin = quantity * (unit_price - unit_cost_pln)'
);

insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price)
  values ('10000000-0000-0000-0000-00000000000a', 900001001, 2, 900001001, 2, 19.99);

select results_eq(
  $$ select line_revenue, line_margin from public.order_lines where order_id = 900001001 and line_no = 2 $$,
  $$ values (39.98::numeric, null::numeric) $$,
  'line_margin is null until the import sets unit_cost_pln'
);

update public.order_lines set unit_cost_pln = 12.49 where order_id = 900001001 and line_no = 2;

select results_eq(
  $$ select line_margin from public.order_lines where order_id = 900001001 and line_no = 2 $$,
  $$ values (15.00::numeric) $$,
  'line_margin recomputes when the import fills unit_cost_pln'
);

select throws_ok(
  $$ insert into public.order_lines (org_id, order_id, line_no, product_id, quantity, unit_price)
     values ('10000000-0000-0000-0000-00000000000a', 900002001, 3, 900001001, 1, 1.00) $$,
  '23503', null,
  'composite foreign keys: an order line cannot point at another org''s order'
);

select throws_ok(
  $$ insert into public.promotions (org_id, promo_code, name, starts_on, ends_on, category_id, product_id, discount_pct)
     values ('10000000-0000-0000-0000-00000000000a', 'BOTH', 'Obie', '2025-01-01', '2025-01-31', 900001001, 900001001, 0.1) $$,
  '23514', null,
  'a promotion targets a category or a product, not both'
);

select * from finish();
rollback;
