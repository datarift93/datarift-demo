-- Every materialized view in `analytics` is refreshed after an import, with CONCURRENTLY
-- (so it needs a unique index). Guards against parallel migrations overwriting
-- private.refresh_analytics() with an incomplete list (happened in Stage 6).
begin;
create extension if not exists pgtap with schema extensions;

select plan(2);

select is_empty(
  $$ select m.matviewname
     from pg_matviews m
     where m.schemaname = 'analytics'
       and pg_get_functiondef('private.refresh_analytics()'::regprocedure)
           not like '%concurrently analytics.' || m.matviewname || ';%' $$,
  'private.refresh_analytics() refreshes every analytics view concurrently'
);

select is_empty(
  $$ select m.matviewname
     from pg_matviews m
     where m.schemaname = 'analytics'
       and not exists (
         select 1 from pg_index i
         join pg_class c on c.oid = i.indrelid
         join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'analytics' and c.relname = m.matviewname
           and i.indisunique and i.indpred is null
       ) $$,
  'every analytics view has a unique index (required by REFRESH CONCURRENTLY)'
);

select * from finish();
rollback;
