-- Stage 5: aggregates for the KPI dashboard (F1), computed in the database.
--
-- Two materialized views, both by local (Warsaw) day and store:
--   analytics.sales_store_day           orders, revenue, margin, units
--   analytics.sales_store_day_category  the same per product category
-- Both are needed: with a category filter, "orders" means orders that CONTAIN that
-- category; without it, summing per-category order counts would count an order with
-- two categories twice.
--
-- Materialized views do not support RLS, so they live in a schema that is not exposed
-- through the Data API. Data leaves only through the SECURITY DEFINER functions below,
-- which check that the caller is a member of the requested org.
--
-- Refreshed after every successful (or partial) import by a trigger on import_runs.
-- Direct writes to the model (admins through the API) are NOT reflected until the next
-- import or a manual `select private.refresh_analytics()`; there is no edit UI in the MVP.

create schema analytics;
revoke all on schema analytics from public, anon, authenticated;

create materialized view analytics.sales_store_day as
select
  o.org_id,
  (o.ordered_at at time zone 'Europe/Warsaw')::date as day,
  o.store_id,
  count(distinct o.id)::integer               as orders,
  sum(l.line_revenue)                         as revenue,
  sum(l.line_margin)                          as margin,
  sum(l.quantity)::bigint                     as units
from public.orders o
join public.order_lines l on l.org_id = o.org_id and l.order_id = o.id
group by o.org_id, 2, o.store_id;

create unique index on analytics.sales_store_day (org_id, day, store_id);

create materialized view analytics.sales_store_day_category as
select
  o.org_id,
  (o.ordered_at at time zone 'Europe/Warsaw')::date as day,
  o.store_id,
  p.category_id,
  count(distinct o.id)::integer               as orders,
  sum(l.line_revenue)                         as revenue,
  sum(l.line_margin)                          as margin,
  sum(l.quantity)::bigint                     as units
from public.orders o
join public.order_lines l on l.org_id = o.org_id and l.order_id = o.id
join public.products p on p.org_id = l.org_id and p.id = l.product_id
group by o.org_id, 2, o.store_id, p.category_id;

create unique index on analytics.sales_store_day_category (org_id, day, store_id, category_id);
create index on analytics.sales_store_day_category (org_id, category_id, day);

-- Refresh ---------------------------------------------------------------------

create function private.refresh_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- CONCURRENTLY (needs the unique indexes above) keeps the dashboard readable while an
  -- import refreshes: a plain REFRESH would lock out every KPI query until the import commits.
  refresh materialized view concurrently analytics.sales_store_day;
  refresh materialized view concurrently analytics.sales_store_day_category;
end $$;

revoke all on function private.refresh_analytics() from public, anon, authenticated;

create function private.refresh_analytics_after_import()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The import just wrote ~450k rows in this transaction; without fresh statistics the
  -- planner picks nested loops for the views' joins (measured: > 7 min instead of seconds).
  analyze public.orders, public.order_lines, public.products, public.stores;
  perform private.refresh_analytics();
  return null;
end $$;

revoke all on function private.refresh_analytics_after_import() from public, anon, authenticated;

create trigger refresh_analytics_after_import
  after update of status on public.import_runs
  for each row
  when (old.status = 'running' and new.status in ('success', 'partial'))
  execute function private.refresh_analytics_after_import();

-- Shared filter -----------------------------------------------------------------

-- Stores matching the channel/region filters (null = all). Used by both KPI functions.
create function private.kpi_stores(p_org_id uuid, p_channel public.sales_channel, p_region_code text)
returns setof bigint
language sql
stable
security definer
set search_path = ''
as $$
  select s.id
  from public.stores s
  left join public.regions r on r.org_id = s.org_id and r.id = s.region_id
  where s.org_id = p_org_id
    and (p_channel is null or s.channel = p_channel)
    and (p_region_code is null or r.region_code = p_region_code)
$$;

revoke all on function private.kpi_stores(uuid, public.sales_channel, text) from public, anon, authenticated;

create function private.assert_org_member(p_org_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_org_id is null or p_org_id not in (select private.user_org_ids()) then
    raise exception 'brak dostępu do organizacji' using errcode = '42501';
  end if;
end $$;

revoke all on function private.assert_org_member(uuid) from public, anon, authenticated;

-- KPI summary -------------------------------------------------------------------

-- Revenue, margin, orders and units for [p_from, p_to] and for the previous period of
-- the same length directly before it. `first_day` is the org's first day with sales,
-- so the UI can tell an incomplete previous period from a real drop.
create function public.kpi_summary(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null
)
returns table (
  period      text,     -- 'current' | 'previous'
  date_from   date,
  date_to     date,
  revenue     numeric,
  margin      numeric,
  orders      bigint,
  units       bigint,
  first_day   date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days   integer := p_to - p_from + 1;
  v_first  date;
  v_cat    bigint;
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  select min(d.day) into v_first from analytics.sales_store_day d where d.org_id = p_org_id;

  if p_category_code is not null then
    select c.id into v_cat from public.categories c
    where c.org_id = p_org_id and c.category_code = p_category_code;
    if v_cat is null then
      raise exception 'nieznana kategoria: %', p_category_code using errcode = '22023';
    end if;
  end if;

  return query
  with periods (period, date_from, date_to) as (
    values ('current', p_from, p_to),
           ('previous', p_from - v_days, p_from - 1)
  ),
  stores as (select private.kpi_stores(p_org_id, p_channel, p_region_code) as id),
  facts as (
    select d.day, d.orders, d.revenue, d.margin, d.units
    from analytics.sales_store_day d
    where v_cat is null and d.org_id = p_org_id and d.store_id in (select id from stores)
      and d.day between p_from - v_days and p_to
    union all
    select d.day, d.orders, d.revenue, d.margin, d.units
    from analytics.sales_store_day_category d
    where v_cat is not null and d.org_id = p_org_id and d.category_id = v_cat
      and d.store_id in (select id from stores)
      and d.day between p_from - v_days and p_to
  )
  select p.period, p.date_from, p.date_to,
         coalesce(sum(f.revenue), 0), coalesce(sum(f.margin), 0),
         coalesce(sum(f.orders), 0)::bigint, coalesce(sum(f.units), 0)::bigint,
         v_first
  from periods p
  left join facts f on f.day between p.date_from and p.date_to
  group by p.period, p.date_from, p.date_to
  order by p.period;
end $$;

-- Revenue over time -------------------------------------------------------------

-- One row per bucket in [p_from, p_to], including empty buckets (0), so the chart has a
-- continuous axis. Grain follows the range: up to 62 days -> day, up to 366 -> ISO week
-- (Monday), longer -> month; `bucket` is the first day of the bucket, clipped to p_from.
create function public.kpi_timeseries(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null
)
returns table (
  grain    text,     -- 'day' | 'week' | 'month'
  bucket   date,
  revenue  numeric,
  margin   numeric,
  orders   bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days  integer := p_to - p_from + 1;
  v_grain text;
  v_cat   bigint;
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;
  v_grain := case when v_days <= 62 then 'day' when v_days <= 366 then 'week' else 'month' end;

  if p_category_code is not null then
    select c.id into v_cat from public.categories c
    where c.org_id = p_org_id and c.category_code = p_category_code;
    if v_cat is null then
      raise exception 'nieznana kategoria: %', p_category_code using errcode = '22023';
    end if;
  end if;

  return query
  with stores as (select private.kpi_stores(p_org_id, p_channel, p_region_code) as id),
  facts as (
    select d.day, d.orders, d.revenue, d.margin
    from analytics.sales_store_day d
    where v_cat is null and d.org_id = p_org_id and d.store_id in (select id from stores)
      and d.day between p_from and p_to
    union all
    select d.day, d.orders, d.revenue, d.margin
    from analytics.sales_store_day_category d
    where v_cat is not null and d.org_id = p_org_id and d.category_id = v_cat
      and d.store_id in (select id from stores)
      and d.day between p_from and p_to
  ),
  buckets as (
    select distinct greatest(date_trunc(v_grain, g)::date, p_from) as bucket
    from generate_series(p_from, p_to, interval '1 day') as g
  )
  select v_grain, b.bucket,
         coalesce(sum(f.revenue), 0), coalesce(sum(f.margin), 0), coalesce(sum(f.orders), 0)::bigint
  from buckets b
  left join facts f on greatest(date_trunc(v_grain, f.day)::date, p_from) = b.bucket
  group by b.bucket
  order by b.bucket;
end $$;

revoke all on function public.kpi_summary(uuid, date, date, public.sales_channel, text, text) from public, anon;
revoke all on function public.kpi_timeseries(uuid, date, date, public.sales_channel, text, text) from public, anon;
grant execute on function public.kpi_summary(uuid, date, date, public.sales_channel, text, text) to authenticated;
grant execute on function public.kpi_timeseries(uuid, date, date, public.sales_channel, text, text) to authenticated;
