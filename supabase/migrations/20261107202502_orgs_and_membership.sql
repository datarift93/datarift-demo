-- Organizations, membership and the RLS helpers every business table will use.
--
-- Access model:
--   * every business row carries org_id;
--   * a user sees rows of orgs they belong to (org_members);
--   * only the `admin` role may write; `demo` is read-only, enforced here and not only in the UI;
--   * orgs and memberships themselves are managed with the service_role key (no self sign-up in MVP).

create type public.org_role as enum ('admin', 'demo');

create table public.orgs (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name       text not null,
  created_at timestamptz not null default now()
);

create table public.org_members (
  org_id     uuid not null references public.orgs (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       public.org_role not null,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

create index org_members_user_id_idx on public.org_members (user_id);

-- Helpers live in a schema that is not exposed through the Data API.
-- SECURITY DEFINER lets policies read org_members without recursing into its own RLS.
create schema if not exists private;
grant usage on schema private to authenticated;

create function private.is_org_member(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.org_members m
    where m.org_id = target_org
      and m.user_id = (select auth.uid())
  );
$$;

create function private.is_org_admin(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.org_members m
    where m.org_id = target_org
      and m.user_id = (select auth.uid())
      and m.role = 'admin'
  );
$$;

revoke all on function private.is_org_member(uuid) from public;
revoke all on function private.is_org_admin(uuid) from public;
grant execute on function private.is_org_member(uuid) to authenticated;
grant execute on function private.is_org_admin(uuid) to authenticated;

-- RLS -----------------------------------------------------------------------

alter table public.orgs enable row level security;
alter table public.org_members enable row level security;

-- Anonymous visitors never read app tables directly. Revoke on existing tables and,
-- through default privileges, on every table/sequence created later in public, so
-- no future migration has to remember it.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;

create policy "members read their orgs"
  on public.orgs for select
  to authenticated
  using ((select private.is_org_member(id)));

-- A user sees their own memberships; an admin sees everyone in their org.
create policy "members read own membership, admins read org"
  on public.org_members for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (select private.is_org_admin(org_id))
  );

-- No insert/update/delete policies on purpose: with RLS on, those are denied for
-- anon and authenticated. Orgs and members are created with service_role.
