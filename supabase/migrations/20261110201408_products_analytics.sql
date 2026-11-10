-- Stage 6: aggregates for the products view (F2): ranking, ABC analysis and margin.
--
-- analytics.sales_product_store_day: revenue, margin, units and orders by local (Warsaw)
-- day, store and product. Store keeps the channel/region filters possible; the product
-- gives the category. `orders` = orders containing the product; an order has one store
-- and one day, so summing it over days and stores never double-counts.
-- Measured on the full dataset (445k lines -> 312k rows): the 2-year ranking is ~27 ms
-- from the view vs ~60-90 ms straight from order_lines.
--
-- Same rules as F1 (*_kpi_analytics.sql): the view lives in `analytics` (not exposed, no
-- RLS on materialized views); data leaves only through the SECURITY DEFINER functions
-- below, which first check membership of the requested org.

-- Re-runnable while Stage 6 sessions share one local database; no-ops on a fresh one.
drop function if exists public.product_abc_summary(uuid, date, date, public.sales_channel, text, text);
drop function if exists public.product_ranking(uuid, date, date, public.sales_channel, text, text);
drop materialized view if exists analytics.sales_product_store_day;

create materialized view analytics.sales_product_store_day as
select
  o.org_id,
  (o.ordered_at at time zone 'Europe/Warsaw')::date as day,
  o.store_id,
  l.product_id,
  sum(l.line_revenue)                         as revenue,
  sum(l.line_margin)                          as margin,
  sum(l.quantity)::bigint                     as units,
  count(distinct o.id)::integer               as orders
from public.orders o
join public.order_lines l on l.org_id = o.org_id and l.order_id = o.id
group by o.org_id, 2, o.store_id, l.product_id;

create unique index on analytics.sales_product_store_day (org_id, day, store_id, product_id);
-- Without statistics the planner estimates a handful of rows and sorts 300k on disk.
analyze analytics.sales_product_store_day;

-- Refresh ---------------------------------------------------------------------

-- Full list: F1 views + F2. Stage 6 sessions each redefine this; the coordinator merges
-- the final version in a separate migration.
create or replace function private.refresh_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  refresh materialized view concurrently analytics.sales_store_day;
  refresh materialized view concurrently analytics.sales_store_day_category;
  refresh materialized view concurrently analytics.sales_product_store_day;
end $$;

revoke all on function private.refresh_analytics() from public, anon, authenticated;

-- Product ranking -----------------------------------------------------------------

-- One row per product with sales in [p_from, p_to] (after the filters), in ABC order:
-- revenue desc, then sku. `cum_share` includes the product itself; the class comes from
-- the cumulative share BEFORE it: < 0.80 -> A, < 0.95 -> B, else C, so the product that
-- crosses 80% is still A and the first product is always A.
-- If every matching line has revenue 0 the shares are null and all products are A.
create function public.product_ranking(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null
)
returns table (
  sku               text,
  product_name      text,
  category_code     text,
  category_name     text,
  purchase_currency public.purchase_currency,
  revenue           numeric,
  margin            numeric,
  margin_pct        numeric,
  units             bigint,
  orders            bigint,
  revenue_share     numeric,
  cum_share         numeric,
  abc_class         text,
  rank              bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cat bigint;
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  if p_category_code is not null then
    select c.id into v_cat from public.categories c
    where c.org_id = p_org_id and c.category_code = p_category_code;
    if v_cat is null then
      raise exception 'nieznana kategoria: %', p_category_code using errcode = '22023';
    end if;
  end if;

  return query
  with stores as (select private.kpi_stores(p_org_id, p_channel, p_region_code) as id),
  agg as (
    select d.product_id,
           sum(d.revenue) as revenue, sum(d.margin) as margin,
           sum(d.units)::bigint as units, sum(d.orders)::bigint as orders
    from analytics.sales_product_store_day d
    where d.org_id = p_org_id
      and d.day between p_from and p_to
      and d.store_id in (select id from stores)
    group by d.product_id
  ),
  facts as (
    select p.sku, p.name as product_name, c.category_code, c.name as category_name,
           p.purchase_currency, a.revenue, a.margin, a.units, a.orders
    from agg a
    join public.products p on p.org_id = p_org_id and p.id = a.product_id
    join public.categories c on c.org_id = p_org_id and c.id = p.category_id
    where v_cat is null or p.category_id = v_cat
  ),
  running as (
    select f.*,
           sum(f.revenue) over () as total,
           sum(f.revenue) over (order by f.revenue desc, f.sku
                                rows between unbounded preceding and current row) as cum,
           row_number() over (order by f.revenue desc, f.sku) as rn
    from facts f
  )
  select r.sku, r.product_name, r.category_code, r.category_name, r.purchase_currency,
         r.revenue, r.margin,
         r.margin / nullif(r.revenue, 0),
         r.units, r.orders,
         r.revenue / nullif(r.total, 0),
         r.cum / nullif(r.total, 0),
         case when r.rn = 1 then 'A'
              when coalesce((r.cum - r.revenue) / nullif(r.total, 0), 0) < 0.80 then 'A'
              when (r.cum - r.revenue) / nullif(r.total, 0) < 0.95 then 'B'
              else 'C' end,
         r.rn
  from running r
  order by r.rn;
end $$;

-- ABC summary -----------------------------------------------------------------------

-- Always three rows (A, B, C), built from product_ranking so the two can never disagree.
-- Shares sum to 1; with no sales the counts are 0 and the shares null.
create function public.product_abc_summary(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null
)
returns table (
  abc_class      text,
  products       bigint,
  revenue        numeric,
  revenue_share  numeric,
  product_share  numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  with ranking as (
    select r.abc_class, r.revenue
    from public.product_ranking(p_org_id, p_from, p_to, p_channel, p_region_code, p_category_code) r
  ),
  totals as (select count(*) as n, sum(revenue) as total from ranking)
  select k.abc_class,
         count(r.abc_class),
         coalesce(sum(r.revenue), 0),
         coalesce(sum(r.revenue), 0) / nullif(t.total, 0),
         count(r.abc_class)::numeric / nullif(t.n, 0)
  from (values ('A'), ('B'), ('C')) as k (abc_class)
  cross join totals t
  left join ranking r on r.abc_class = k.abc_class
  group by k.abc_class, t.n, t.total
  order by k.abc_class
$$;

revoke all on function public.product_ranking(uuid, date, date, public.sales_channel, text, text) from public, anon;
revoke all on function public.product_abc_summary(uuid, date, date, public.sales_channel, text, text) from public, anon;
grant execute on function public.product_ranking(uuid, date, date, public.sales_channel, text, text) to authenticated;
grant execute on function public.product_abc_summary(uuid, date, date, public.sales_channel, text, text) to authenticated;
