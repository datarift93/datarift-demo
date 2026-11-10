-- Stage 6: plan vs actual (F6), computed in the database.
--
-- The plan is public.budgets (store x month). The actual comes from the existing
-- analytics.sales_store_day (F1), summed to months; ~20k rows for two years, so no new
-- materialized view is needed (and private.refresh_analytics() is left untouched).
--
-- Re-runnable while iterating on a shared local database: drops only its own function.

drop function if exists public.plan_vs_actual(uuid, date, date, public.sales_channel, text, text);

-- Plan vs actual for the FULL months inside [p_from, p_to] (a partial month compared with
-- a full-month plan would mislead), on three levels from one GROUPING SETS query:
--   level 'store'   one row per store and month, plus a period total (month null)
--   level 'region'  the same per region; the online store has no region and forms its
--                   own group (region_code null, region_name 'Sklep internetowy')
--   level 'network' the same for all stores matching the filters
-- Channel and region filter the stores. The budget is per store, not per category, so
-- p_category_code is accepted for a uniform signature and ignored (the UI says so).
-- A store-month appears when it has a budget or sales; plan = 0 without a budget, and
-- then realization is null. No full month (or no matching store) -> no rows.
create function public.plan_vs_actual(
  p_org_id        uuid,
  p_from          date,
  p_to            date,
  p_channel       public.sales_channel default null,
  p_region_code   text default null,
  p_category_code text default null
)
returns table (
  level        text,     -- 'store' | 'region' | 'network'
  store_code   text,
  store_name   text,
  region_code  text,
  region_name  text,
  month        date,     -- first day of the month; null = total for the period
  plan         numeric,
  actual       numeric,
  realization  numeric,  -- actual / plan; null when plan = 0
  deviation    numeric   -- actual - plan
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_first date;  -- first full month
  v_last  date;  -- last full month (its first day)
begin
  perform private.assert_org_member(p_org_id);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'niepoprawny okres' using errcode = '22023';
  end if;

  v_first := case when extract(day from p_from) = 1 then p_from
                  else (date_trunc('month', p_from) + interval '1 month')::date end;
  v_last  := (date_trunc('month', p_to + 1) - interval '1 month')::date;
  if v_first > v_last then
    return;
  end if;

  return query
  with stores as (
    select s.id, s.store_code, s.name as store_name, r.region_code,
           coalesce(r.name, 'Sklep internetowy') as region_name
    from public.stores s
    left join public.regions r on r.org_id = s.org_id and r.id = s.region_id
    where s.org_id = p_org_id
      and s.id in (select private.kpi_stores(p_org_id, p_channel, p_region_code))
  ),
  actuals as (
    select d.store_id, date_trunc('month', d.day)::date as month, sum(d.revenue) as revenue
    from analytics.sales_store_day d
    where d.org_id = p_org_id
      and d.store_id in (select id from stores)
      and d.day between v_first and (v_last + interval '1 month' - interval '1 day')::date
    group by 1, 2
  ),
  plans as (
    select b.store_id, b.month, b.revenue_plan
    from public.budgets b
    where b.org_id = p_org_id
      and b.store_id in (select id from stores)
      and b.month between v_first and v_last
  ),
  base as (
    select st.store_code, st.store_name, st.region_code, st.region_name,
           coalesce(p.month, a.month) as month,
           coalesce(p.revenue_plan, 0) as plan,
           coalesce(a.revenue, 0) as actual
    from plans p
    full join actuals a on a.store_id = p.store_id and a.month = p.month
    join stores st on st.id = coalesce(p.store_id, a.store_id)
  ),
  grouped as (
    select
      case when grouping(b.store_code) = 0 then 'store'
           when grouping(b.region_name) = 0 then 'region'
           else 'network' end as level,
      b.store_code, b.store_name, b.region_code, b.region_name, b.month,
      sum(b.plan) as plan, sum(b.actual) as actual
    from base b
    group by grouping sets (
      (b.store_code, b.store_name, b.region_code, b.region_name, b.month),
      (b.store_code, b.store_name, b.region_code, b.region_name),
      (b.region_code, b.region_name, b.month),
      (b.region_code, b.region_name),
      (b.month),
      ()
    )
    having count(*) > 0  -- the empty grouping set yields a row even with no input
  )
  select g.level, g.store_code, g.store_name, g.region_code, g.region_name, g.month,
         g.plan, g.actual,
         case when g.plan = 0 then null else g.actual / g.plan end,
         g.actual - g.plan
  from grouped g
  order by case g.level when 'network' then 0 when 'region' then 1 else 2 end,
           g.region_name, g.store_code, g.month nulls first;
end $$;

revoke all on function public.plan_vs_actual(uuid, date, date, public.sales_channel, text, text) from public, anon;
grant execute on function public.plan_vs_actual(uuid, date, date, public.sales_channel, text, text) to authenticated;
