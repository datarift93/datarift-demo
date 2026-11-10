-- Stage 6 / F3 Klienci: RFM segments and monthly retention cohorts, computed in the database.
--
-- Only identified customers (orders.customer_id is not null). Filters:
--   channel  = channel of the ORDER's store (a customer can buy in both channels),
--   region   = the CUSTOMER's region (customers.region_id), not the store's,
--   category = ignored (the UI says so).
--
-- One materialized view, analytics.customer_day (customer x Warsaw day x channel: orders and
-- revenue). ~135k identified orders collapse to ~130k rows; both functions read only this
-- view plus `customers`, so no call touches order_lines. Like the F1 views it lives in the
-- unexposed `analytics` schema and data leaves only through the SECURITY DEFINER functions
-- below, which check org membership first. 20k customers never leave the database: the
-- functions return aggregates only (6 segments, 15 score bands, <= 24 x 24 cohort cells).
--
-- Written to be re-runnable while three Stage 6 sessions share one local database:
-- drops only the objects this migration creates.

drop function if exists public.customer_rfm_segments(uuid, date, date, public.sales_channel, text, text);
drop function if exists public.customer_rfm_scores(uuid, date, date, public.sales_channel, text, text);
drop function if exists public.customer_cohorts(uuid, date, date, public.sales_channel, text, text);
drop function if exists private.customer_rfm(uuid, date, public.sales_channel, text);
drop materialized view if exists analytics.customer_day;

create materialized view analytics.customer_day as
select
  o.org_id,
  o.customer_id,
  (o.ordered_at at time zone 'Europe/Warsaw')::date as day,
  s.channel,
  count(distinct o.id)::integer                     as orders,
  sum(l.line_revenue)                               as revenue
from public.orders o
join public.order_lines l on l.org_id = o.org_id and l.order_id = o.id
join public.stores s on s.org_id = o.org_id and s.id = o.store_id
where o.customer_id is not null
group by o.org_id, o.customer_id, 3, s.channel;

create unique index on analytics.customer_day (org_id, customer_id, day, channel);

-- Refresh ---------------------------------------------------------------------
-- Full list: F1 views + F3. The F2/F6 sessions redefine this function with their own views;
-- the coordinator merges the final version in a separate migration.

create or replace function private.refresh_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- CONCURRENTLY (needs the unique indexes) keeps the dashboards readable while an import
  -- refreshes: a plain REFRESH would lock out every query until the import commits.
  refresh materialized view concurrently analytics.sales_store_day;
  refresh materialized view concurrently analytics.sales_store_day_category;
  refresh materialized view concurrently analytics.customer_day;
end $$;

revoke all on function private.refresh_analytics() from public, anon, authenticated;

-- Per-customer RFM (private) ----------------------------------------------------

-- One row per customer with >= 1 order on or before p_to that matches the filters.
-- Reference date = p_to; the F/M window is the 365 days ending on p_to (inclusive).
-- Scores 1-5 by ntile(5): R by recency ascending (most recent = 5), F and M descending
-- (most = 5); ties broken by customer_code, so equal values may land in neighbouring
-- scores, but the result is deterministic. Customers with no order in the window have
-- F = 0 and M = 0 and sort to the bottom of both rankings.
-- Not callable by clients: the public functions check membership before calling it.
create function private.customer_rfm(
  p_org_id      uuid,
  p_to          date,
  p_channel     public.sales_channel,
  p_region_code text
)
returns table (
  customer_id   bigint,
  recency_days  integer,
  frequency     bigint,
  monetary      numeric,
  r_score       integer,
  f_score       integer,
  m_score       integer,
  segment_no    integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with per_customer as (
    select d.customer_id,
           c.customer_code,
           p_to - max(d.day)                                                        as recency_days,
           coalesce(sum(d.orders) filter (where d.day > p_to - 365), 0)::bigint     as frequency,
           coalesce(sum(d.revenue) filter (where d.day > p_to - 365), 0)            as monetary
    from analytics.customer_day d
    join public.customers c on c.org_id = d.org_id and c.id = d.customer_id
    where d.org_id = p_org_id
      and d.day <= p_to
      and (p_channel is null or d.channel = p_channel)
      and (p_region_code is null or c.region_id = (
            select r.id from public.regions r
            where r.org_id = p_org_id and r.region_code = p_region_code))
    group by d.customer_id, c.customer_code
  ),
  scored as (
    select pc.*,
           ntile(5) over (order by pc.recency_days desc, pc.customer_code)::integer as r_score,
           ntile(5) over (order by pc.frequency, pc.customer_code)::integer         as f_score,
           ntile(5) over (order by pc.monetary, pc.customer_code)::integer          as m_score
    from per_customer pc
  )
  select s.customer_id, s.recency_days, s.frequency, s.monetary, s.r_score, s.f_score, s.m_score,
         -- First matching rule (docs/stage6-spec.md, F3). R is always 1-5, so every
         -- customer gets exactly one segment.
         -- "Nowi" deviates from the spec's "F score <= 1": with > 20% of customers having
         -- no order in the window, F score 1 holds only F = 0, which can never meet R >= 4,
         -- so the segment was always empty. Here: recent AND exactly one order in the window.
         case
           when s.r_score >= 4 and s.f_score >= 4 then 1  -- Mistrzowie
           when s.f_score >= 4                    then 2  -- Lojalni
           when s.r_score >= 4 and s.frequency = 1 then 3 -- Nowi
           when s.r_score >= 3                    then 4  -- Obiecujący
           when s.r_score = 2                     then 5  -- Zagrożeni odejściem
           else                                        6  -- Utraceni (R = 1)
         end
  from scored s
$$;

revoke all on function private.customer_rfm(uuid, date, public.sales_channel, text) from public, anon, authenticated;

-- RFM segments --------------------------------------------------------------------

-- Always 6 rows in the rule order. `revenue` is M summed over the segment (revenue in the
-- 365-day window), shares are of all scored customers / of their window revenue
-- (0 when there are none). Averages are null for an empty segment.
-- p_from only validates the period: the RFM reference date is p_to.
create function public.customer_rfm_segments(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null  -- ignored: segments are about customers, not categories
)
returns table (
  segment           text,
  customers         bigint,
  revenue           numeric,
  avg_recency_days  numeric,
  avg_frequency     numeric,
  share_customers   numeric,
  share_revenue     numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  return query
  with rfm as (select * from private.customer_rfm(p_org_id, p_to, p_channel, p_region_code)),
  segments (segment_no, segment) as (
    values (1, 'Mistrzowie'), (2, 'Lojalni'), (3, 'Nowi'), (4, 'Obiecujący'),
           (5, 'Zagrożeni odejściem'), (6, 'Utraceni')
  ),
  per_segment as (
    select s.segment_no, s.segment,
           count(r.customer_id)                 as customers,
           coalesce(sum(r.monetary), 0)         as revenue,
           avg(r.recency_days)::numeric         as avg_recency_days,
           avg(r.frequency)::numeric            as avg_frequency
    from segments s
    left join rfm r on r.segment_no = s.segment_no
    group by s.segment_no, s.segment
  )
  select ps.segment, ps.customers, ps.revenue, ps.avg_recency_days, ps.avg_frequency,
         coalesce(ps.customers / nullif(sum(ps.customers) over (), 0), 0)::numeric,
         coalesce(ps.revenue / nullif(sum(ps.revenue) over (), 0), 0)::numeric
  from per_segment ps
  order by ps.segment_no;
end $$;

-- RFM score bands -------------------------------------------------------------------

-- What each score means for the current filters: 15 rows (dimension R/F/M x score 1-5)
-- with the number of customers and the value range of the band. Lets the UI explain the
-- scores without sending per-customer rows.
create function public.customer_rfm_scores(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null  -- ignored
)
returns table (
  dimension  text,     -- 'R' (days since last order) | 'F' (orders) | 'M' (revenue, PLN)
  score      integer,
  customers  bigint,
  min_value  numeric,
  max_value  numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  return query
  with rfm as (select * from private.customer_rfm(p_org_id, p_to, p_channel, p_region_code)),
  bands as (
    select 'R'::text as dimension, r.r_score as score, r.recency_days::numeric as v from rfm r
    union all
    select 'F', r.f_score, r.frequency::numeric from rfm r
    union all
    select 'M', r.m_score, r.monetary from rfm r
  )
  select b.dimension, b.score, count(*), min(b.v), max(b.v)
  from bands b
  group by b.dimension, b.score
  order by array_position(array['R', 'F', 'M'], b.dimension), b.score;
end $$;

-- Retention cohorts -----------------------------------------------------------------

-- Cohort = month of the customer's first order in the whole history (among orders that
-- match the channel filter; region = the customer's). Only cohorts whose first order day
-- falls in [p_from, p_to]. For each cohort: one row per months_since from 0 to the last
-- full month of the org's data (every cell present, 0 when nobody returned), so the matrix
-- is a complete triangle. `active_customers` = cohort members with >= 1 matching order in
-- that calendar month; month 0 is always 100%. A cohort in a partial last month gets only
-- month 0.
create function public.customer_cohorts(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null  -- ignored
)
returns table (
  cohort_month      date,
  months_since      integer,
  cohort_size       bigint,
  active_customers  bigint,
  retention         numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_end        date;
  v_last_month date;
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  select max(d.day) into v_end from analytics.customer_day d where d.org_id = p_org_id;
  if v_end is null then
    return;
  end if;
  -- Last full month: the month of v_end if v_end is its last day, else the month before.
  v_last_month := case
    when v_end = (date_trunc('month', v_end) + interval '1 month - 1 day')::date
      then date_trunc('month', v_end)::date
    else (date_trunc('month', v_end) - interval '1 month')::date
  end;

  return query
  with activity as (
    select d.customer_id, date_trunc('month', d.day)::date as month, min(d.day) as first_day
    from analytics.customer_day d
    join public.customers c on c.org_id = d.org_id and c.id = d.customer_id
    where d.org_id = p_org_id
      and (p_channel is null or d.channel = p_channel)
      and (p_region_code is null or c.region_id = (
            select r.id from public.regions r
            where r.org_id = p_org_id and r.region_code = p_region_code))
    group by d.customer_id, 2
  ),
  members as (
    select a.customer_id, min(a.month) as cohort_month
    from activity a
    group by a.customer_id
    having min(a.first_day) between p_from and p_to
  ),
  sizes as (
    select m.cohort_month, count(*) as cohort_size from members m group by m.cohort_month
  ),
  returned as (
    select m.cohort_month,
           ((extract(year from a.month) - extract(year from m.cohort_month)) * 12
             + extract(month from a.month) - extract(month from m.cohort_month))::integer as months_since,
           count(*) as active_customers
    from members m
    join activity a on a.customer_id = m.customer_id
    group by 1, 2
  ),
  grid as (
    select s.cohort_month, s.cohort_size, k.months_since
    from sizes s
    cross join lateral generate_series(
      0,
      greatest(0, ((extract(year from v_last_month) - extract(year from s.cohort_month)) * 12
                   + extract(month from v_last_month) - extract(month from s.cohort_month))::integer)
    ) as k(months_since)
  )
  select g.cohort_month, g.months_since, g.cohort_size,
         coalesce(r.active_customers, 0),
         (coalesce(r.active_customers, 0)::numeric / g.cohort_size)
  from grid g
  left join returned r on r.cohort_month = g.cohort_month and r.months_since = g.months_since
  order by g.cohort_month, g.months_since;
end $$;

revoke all on function public.customer_rfm_segments(uuid, date, date, public.sales_channel, text, text) from public, anon;
revoke all on function public.customer_rfm_scores(uuid, date, date, public.sales_channel, text, text) from public, anon;
revoke all on function public.customer_cohorts(uuid, date, date, public.sales_channel, text, text) from public, anon;
grant execute on function public.customer_rfm_segments(uuid, date, date, public.sales_channel, text, text) to authenticated;
grant execute on function public.customer_rfm_scores(uuid, date, date, public.sales_channel, text, text) to authenticated;
grant execute on function public.customer_cohorts(uuid, date, date, public.sales_channel, text, text) to authenticated;
