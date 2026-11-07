-- Local development seed (runs on `supabase db reset`). Never used in production.
--
-- Creates the demo organization and the read-only demo account used by the
-- one-click "Zobacz demo" login. The demo password is not a secret: anyone can
-- log in as demo, and RLS keeps the account read-only.

insert into public.orgs (id, slug, name)
values ('00000000-0000-0000-0000-00000000a001', 'wisla-demo', 'Wisła (demo)');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-00000000d001',
  'authenticated', 'authenticated',
  'demo@datarift.local',
  extensions.crypt('demo-local-only', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}', '{}',
  now(), now(),
  '', '', '', ''
);

insert into auth.identities (
  id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at
)
values (
  gen_random_uuid(),
  '00000000-0000-0000-0000-00000000d001',
  '00000000-0000-0000-0000-00000000d001',
  'email',
  '{"sub":"00000000-0000-0000-0000-00000000d001","email":"demo@datarift.local","email_verified":true}',
  now(), now(), now()
);

insert into public.org_members (org_id, user_id, role)
values ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000d001', 'demo');
