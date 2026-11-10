-- Stage 6 integration: one refresh for every analytics view.
--
-- The F2 (products) and F3 (customers) migrations were written in parallel; each redefined
-- private.refresh_analytics() with F1's views plus its own, and the later one (F3) would
-- silently drop F2's view from the refresh. This migration, applied after both, lists all
-- of them. Test 009_analytics_refresh.test.sql fails if a view in `analytics` is ever
-- missing here again.
create or replace function private.refresh_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- CONCURRENTLY keeps the dashboards readable during an import (needs a unique index).
  refresh materialized view concurrently analytics.sales_store_day;           -- F1
  refresh materialized view concurrently analytics.sales_store_day_category;  -- F1
  refresh materialized view concurrently analytics.sales_product_store_day;   -- F2
  refresh materialized view concurrently analytics.customer_day;              -- F3
end $$;

revoke all on function private.refresh_analytics() from public, anon, authenticated;
