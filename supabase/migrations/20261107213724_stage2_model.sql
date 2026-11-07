-- Stage 2: analytical model (dimensions, facts, global reference tables).
-- Follows docs/data-model.md section 3.
--
-- Conventions:
--   * technical keys: bigint generated always as identity;
--   * business codes from the CSV files are unique per org_id;
--   * every org-scoped table also has unique (org_id, id), so foreign keys are
--     composite (org_id, <ref>_id) and a row can never point at another org's row;
--   * money: numeric(12,2);
--   * columns filled by the Stage 3 import (fx_rate, unit_cost_pln) are nullable for now.

create type public.sales_channel as enum ('store', 'online');
create type public.purchase_currency as enum ('PLN', 'EUR');

-- Dimensions ----------------------------------------------------------------

create table public.regions (
  id                     bigint generated always as identity primary key,
  org_id                 uuid not null references public.orgs (id) on delete cascade,
  region_code            text not null,
  name                   text not null,
  purchasing_power_index numeric(6,3) not null check (purchasing_power_index > 0),
  unique (org_id, region_code),
  unique (org_id, id)
);

create table public.stores (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.orgs (id) on delete cascade,
  store_code  text not null,
  name        text not null,
  channel     public.sales_channel not null,
  city        text,
  region_id   bigint,
  size_m2     integer check (size_m2 > 0),
  opened_on   date not null,
  unique (org_id, store_code),
  unique (org_id, id),
  foreign key (org_id, region_id) references public.regions (org_id, id),
  -- Physical stores have a location and size; the online store has none.
  check (
    (channel = 'store' and city is not null and region_id is not null and size_m2 is not null)
    or (channel = 'online' and city is null and region_id is null and size_m2 is null)
  )
);

create table public.categories (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  category_code text not null,
  name          text not null,
  unique (org_id, category_code),
  unique (org_id, id)
);

create table public.products (
  id                bigint generated always as identity primary key,
  org_id            uuid not null references public.orgs (id) on delete cascade,
  sku               text not null,
  name              text not null,
  category_id       bigint not null,
  list_price        numeric(12,2) not null check (list_price >= 0),
  purchase_currency public.purchase_currency not null,
  unique (org_id, sku),
  unique (org_id, id),
  foreign key (org_id, category_id) references public.categories (org_id, id)
);

create index products_org_category_idx on public.products (org_id, category_id);

create table public.customers (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  customer_code text not null,
  region_id     bigint not null,
  registered_on date not null,
  unique (org_id, customer_code),
  unique (org_id, id),
  foreign key (org_id, region_id) references public.regions (org_id, id)
);

create index customers_org_region_idx on public.customers (org_id, region_id);

-- category_id null and product_id null = the whole assortment.
create table public.promotions (
  id           bigint generated always as identity primary key,
  org_id       uuid not null references public.orgs (id) on delete cascade,
  promo_code   text not null,
  name         text not null,
  starts_on    date not null,
  ends_on      date not null,
  category_id  bigint,
  product_id   bigint,
  discount_pct numeric(5,4) not null check (discount_pct >= 0 and discount_pct <= 1),
  unique (org_id, promo_code),
  unique (org_id, id),
  foreign key (org_id, category_id) references public.categories (org_id, id),
  foreign key (org_id, product_id) references public.products (org_id, id),
  check (starts_on <= ends_on),
  -- A promotion targets one category, one product, or (both null) everything.
  check (category_id is null or product_id is null)
);

-- Facts ---------------------------------------------------------------------

-- The sales channel is not stored here: it follows from the store.
create table public.orders (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references public.orgs (id) on delete cascade,
  order_code  text not null,
  store_id    bigint not null,
  customer_id bigint, -- null = anonymous in-store purchase (no loyalty card)
  ordered_at  timestamptz not null,
  unique (org_id, order_code),
  unique (org_id, id),
  foreign key (org_id, store_id) references public.stores (org_id, id),
  foreign key (org_id, customer_id) references public.customers (org_id, id)
);

create index orders_org_ordered_at_idx on public.orders (org_id, ordered_at);
create index orders_org_store_ordered_at_idx on public.orders (org_id, store_id, ordered_at);
create index orders_org_customer_idx on public.orders (org_id, customer_id) where customer_id is not null;

create table public.order_lines (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  order_id      bigint not null,
  line_no       integer not null check (line_no > 0),
  product_id    bigint not null,
  quantity      integer not null check (quantity > 0),
  unit_price    numeric(12,2) not null check (unit_price >= 0), -- after discount
  promotion_id  bigint,
  -- Filled by the import: weighted average purchase cost of the product
  -- over the 90 days before the order date.
  unit_cost_pln numeric(12,2) check (unit_cost_pln >= 0),
  line_revenue  numeric(12,2) generated always as (quantity * unit_price) stored,
  line_margin   numeric(12,2) generated always as (quantity * (unit_price - unit_cost_pln)) stored,
  -- Also serves the contract's order_lines (org_id, order_id) index (leading columns).
  unique (org_id, order_id, line_no),
  foreign key (org_id, order_id) references public.orders (org_id, id) on delete cascade,
  foreign key (org_id, product_id) references public.products (org_id, id),
  foreign key (org_id, promotion_id) references public.promotions (org_id, id)
);

create index order_lines_org_product_idx on public.order_lines (org_id, product_id);

-- Supplier purchases. fx_rate and unit_cost_pln are filled by the import
-- (NBP rate from the purchase date or the last business day before it).
create table public.purchases (
  id            bigint generated always as identity primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  purchase_code text not null,
  product_id    bigint not null,
  purchase_date date not null,
  quantity      integer not null check (quantity > 0),
  unit_cost     numeric(12,2) not null check (unit_cost >= 0), -- in the purchase currency
  currency      public.purchase_currency not null,
  fx_rate       numeric(10,4) check (fx_rate > 0),
  unit_cost_pln numeric(12,2) check (unit_cost_pln >= 0),
  unique (org_id, purchase_code),
  unique (org_id, id),
  foreign key (org_id, product_id) references public.products (org_id, id)
);

-- For the 90-day weighted average cost computed by the import.
create index purchases_org_product_date_idx on public.purchases (org_id, product_id, purchase_date);

create table public.budgets (
  id           bigint generated always as identity primary key,
  org_id       uuid not null references public.orgs (id) on delete cascade,
  store_id     bigint not null,
  month        date not null check (extract(day from month) = 1),
  revenue_plan numeric(12,2) not null check (revenue_plan >= 0),
  unique (org_id, store_id, month),
  unique (org_id, id),
  foreign key (org_id, store_id) references public.stores (org_id, id)
);

-- Global reference tables (no org_id) ---------------------------------------

-- NBP table A mid rates, EUR/PLN. Public data shared by all orgs.
create table public.fx_rates (
  rate_date date primary key, -- NBP publication days only
  mid_rate  numeric(10,4) not null check (mid_rate > 0),
  table_no  text not null unique
);

-- Rows are inserted by the calendar migration.
create table public.calendar (
  date                 date primary key,
  year                 smallint not null,
  quarter              smallint not null,
  month                smallint not null,
  iso_year             smallint not null,
  iso_week             smallint not null,
  day_of_week          smallint not null check (day_of_week between 1 and 7), -- ISO: 1 = Monday
  is_weekend           boolean not null,
  is_holiday           boolean not null, -- Polish public holiday (dzień ustawowo wolny od pracy)
  holiday_name         text,
  is_trading_sunday    boolean not null, -- Sunday on which shops may open (Sunday trading ban)
  is_store_trading_day boolean not null, -- physical stores open: not a holiday, not a non-trading Sunday
  is_short_trading_day boolean not null, -- stores open but close around 14:00 (Holy Saturday, 24 Dec before 2025, 31 Dec)
  is_black_friday      boolean not null,
  is_cyber_monday      boolean not null,
  check (is_holiday = (holiday_name is not null)),
  check (not is_trading_sunday or day_of_week = 7),
  check (not is_short_trading_day or is_store_trading_day)
);

-- RLS helpers ---------------------------------------------------------------

-- Set-based variants of private.is_org_member / private.is_org_admin. A policy like
-- `org_id in (select private.user_org_ids())` runs the subquery once per statement
-- (hashed), instead of calling a function for every row: aggregates over the fact
-- tables would otherwise pay one function call per row.
create function private.user_org_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.org_id from public.org_members m where m.user_id = (select auth.uid());
$$;

create function private.admin_org_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.org_id from public.org_members m
  where m.user_id = (select auth.uid()) and m.role = 'admin';
$$;

revoke all on function private.user_org_ids() from public;
revoke all on function private.admin_org_ids() from public;
grant execute on function private.user_org_ids() to authenticated;
grant execute on function private.admin_org_ids() to authenticated;

-- Stage 1 policies, same rules, rewritten with the set-based helpers.
drop policy "members read their orgs" on public.orgs;
create policy "members read their orgs"
  on public.orgs for select
  to authenticated
  using (id in (select private.user_org_ids()));

drop policy "members read own membership, admins read org" on public.org_members;
create policy "members read own membership, admins read org"
  on public.org_members for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or org_id in (select private.admin_org_ids())
  );

-- A row never moves between orgs, not even for an admin of both (RLS alone would
-- allow it) or for service_role. Fires before RLS checks.
create function private.prevent_org_id_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.org_id is distinct from old.org_id then
    raise exception 'org_id cannot be changed (table %)', tg_table_name
      using errcode = '23514';
  end if;
  return new;
end $$;

revoke all on function private.prevent_org_id_change() from public;

-- RLS -----------------------------------------------------------------------

-- Org-scoped tables: members read their org, only admins write it.
do $$
declare
  t text;
begin
  foreach t in array array[
    'regions', 'stores', 'categories', 'products', 'customers', 'promotions',
    'orders', 'order_lines', 'purchases', 'budgets'
  ] loop
    execute format('alter table public.%I enable row level security', t);

    execute format(
      'create policy "members read own org" on public.%I for select to authenticated
         using (org_id in (select private.user_org_ids()))', t);
    execute format(
      'create policy "admins insert own org" on public.%I for insert to authenticated
         with check (org_id in (select private.admin_org_ids()))', t);
    execute format(
      'create policy "admins update own org" on public.%I for update to authenticated
         using (org_id in (select private.admin_org_ids()))
         with check (org_id in (select private.admin_org_ids()))', t);
    execute format(
      'create policy "admins delete own org" on public.%I for delete to authenticated
         using (org_id in (select private.admin_org_ids()))', t);

    execute format(
      'create trigger prevent_org_id_change before update of org_id on public.%I
         for each row execute function private.prevent_org_id_change()', t);
  end loop;
end $$;

-- Global tables: read-only for signed-in users; written by the import (service_role).
alter table public.fx_rates enable row level security;
alter table public.calendar enable row level security;

create policy "authenticated read" on public.fx_rates for select to authenticated using (true);
create policy "authenticated read" on public.calendar for select to authenticated using (true);

revoke insert, update, delete on public.fx_rates, public.calendar from authenticated;

-- TRUNCATE ignores RLS, and Supabase grants it to authenticated by default.
-- Revoke it on every table in public (including orgs/org_members) and for future tables.
revoke truncate on all tables in schema public from authenticated;
alter default privileges for role postgres in schema public revoke truncate on tables from authenticated;

-- anon is already revoked through default privileges (orgs_and_membership migration);
-- tests in 002_model.test.sql check it for every table here.
