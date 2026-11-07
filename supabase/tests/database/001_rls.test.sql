-- RLS tests for orgs and membership. Run with `supabase test db`.
-- Everything runs in a transaction that is rolled back at the end.
begin;
create extension if not exists pgtap with schema extensions;

select plan(18);

-- Guard for every future table: RLS must be on everywhere in public.
select is_empty(
  $$ select c.relname
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity $$,
  'every table in public has RLS enabled'
);

-- Fixtures: two orgs, an admin and a demo user in org A, an admin in org B.
insert into public.orgs (id, slug, name) values
  ('10000000-0000-0000-0000-00000000000a', 'org-a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'org-b', 'Org B');

insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-0000000000a1', 'admin-a@test.local'),
  ('20000000-0000-0000-0000-0000000000a2', 'demo-a@test.local'),
  ('20000000-0000-0000-0000-0000000000b1', 'admin-b@test.local');

insert into public.org_members (org_id, user_id, role) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'admin'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a2', 'demo'),
  ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000b1', 'admin');

-- Act as a given user (or anon) the way PostgREST does.
create function pg_temp.login_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

-- anon ---------------------------------------------------------------------
set local role anon;
select throws_ok(
  $$ select * from public.orgs $$,
  '42501', null,
  'anon has no access to orgs'
);
reset role;

-- demo user in org A ---------------------------------------------------------
select pg_temp.login_as('20000000-0000-0000-0000-0000000000a2');

select results_eq(
  $$ select slug from public.orgs order by slug $$,
  $$ values ('org-a') $$,
  'demo user sees only their own org'
);

select results_eq(
  $$ select count(*)::int from public.org_members $$,
  $$ values (1) $$,
  'demo user sees only their own membership'
);

select throws_ok(
  $$ insert into public.orgs (slug, name) values ('hack', 'Hack') $$,
  '42501', null,
  'demo user cannot create orgs'
);

select throws_ok(
  $$ insert into public.org_members (org_id, user_id, role)
     values ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000a2', 'admin') $$,
  '42501', null,
  'demo user cannot add memberships (no privilege escalation)'
);

update public.org_members set role = 'admin'
  where user_id = '20000000-0000-0000-0000-0000000000a2';
update public.orgs set name = 'Hacked';
delete from public.orgs;
reset role;

select results_eq(
  $$ select role::text from public.org_members where user_id = '20000000-0000-0000-0000-0000000000a2' $$,
  $$ values ('demo') $$,
  'demo user cannot change their own role'
);

select results_eq(
  $$ select count(*)::int from public.orgs where name in ('Org A', 'Org B') $$,
  $$ values (2) $$,
  'demo user cannot rename or delete orgs'
);

-- admin in org A -------------------------------------------------------------
select pg_temp.login_as('20000000-0000-0000-0000-0000000000a1');

select results_eq(
  $$ select slug from public.orgs order by slug $$,
  $$ values ('org-a') $$,
  'admin sees only their own org'
);

select results_eq(
  $$ select count(*)::int from public.org_members $$,
  $$ values (2) $$,
  'admin sees all members of their org, none from other orgs'
);

select is(
  (select private.is_org_admin('10000000-0000-0000-0000-00000000000a')),
  true,
  'is_org_admin is true for own org'
);

select is(
  (select private.is_org_admin('10000000-0000-0000-0000-00000000000b')),
  false,
  'is_org_admin is false for another org'
);

-- Orgs and memberships are managed with service_role only, even admins cannot write them.
select throws_ok(
  $$ insert into public.orgs (slug, name) values ('admin-org', 'Admin Org') $$,
  '42501', null,
  'admin cannot create orgs through the API'
);

select throws_ok(
  $$ insert into public.org_members (org_id, user_id, role)
     values ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000a1', 'admin') $$,
  '42501', null,
  'admin cannot join another org'
);

update public.org_members set role = 'admin'
  where user_id = '20000000-0000-0000-0000-0000000000a2';
delete from public.org_members
  where org_id = '10000000-0000-0000-0000-00000000000a';
reset role;

select results_eq(
  $$ select user_id::text, role::text from public.org_members
     where org_id = '10000000-0000-0000-0000-00000000000a' order by user_id $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1', 'admin'),
            ('20000000-0000-0000-0000-0000000000a2', 'demo') $$,
  'admin cannot change roles or remove members through the API'
);

-- Default privileges: a table created by a future migration gets no anon grants.
create table public.future_table (id int);
select is(
  has_table_privilege('anon', 'public.future_table', 'select'),
  false,
  'new tables in public are not granted to anon by default'
);
drop table public.future_table;

-- user without any membership -----------------------------------------------
insert into auth.users (id, email) values ('20000000-0000-0000-0000-0000000000c1', 'nobody@test.local');
select pg_temp.login_as('20000000-0000-0000-0000-0000000000c1');

select is_empty($$ select * from public.orgs $$, 'user without membership sees no orgs');
select is_empty($$ select * from public.org_members $$, 'user without membership sees no memberships');
reset role;

select * from finish();
rollback;
