-- Flashcard app: Supabase database schema
-- Run this whole file in Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  display_name text not null default 'Người học',
  gender text not null default 'female' check (gender in ('female','male')),
  role text not null default 'user' check (role in ('user','admin')),
  status text not null default 'active' check (status in ('active','suspended','expired')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.decks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  cards jsonb not null default '[]'::jsonb,
  sort_order integer not null default 0,
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.progress (
  user_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null,
  level integer not null default 0 check (level between 0 and 5),
  streak integer not null default 0,
  seen integer not null default 0,
  correct integer not null default 0,
  wrong integer not null default 0,
  last_seen_at timestamptz,
  next_due_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, card_id)
);

create table if not exists public.study_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  deck_id text,
  deck_name text not null,
  total integer not null default 0,
  correct integer not null default 0,
  avg_ms integer not null default 0,
  started_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.user_usage (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  usage_ms bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  type text not null default 'Tài liệu',
  url text,
  description text,
  content text,
  is_published boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.terms_acceptances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  terms_version text not null,
  accepted_at timestamptz not null default now()
);

create index if not exists idx_progress_user on public.progress(user_id);
create index if not exists idx_sessions_user_date on public.study_sessions(user_id, started_at desc);
create index if not exists idx_resources_published on public.resources(is_published, created_at desc);

-- Keep updated_at current.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at before update on public.profiles
for each row execute function public.touch_updated_at();

drop trigger if exists trg_decks_updated_at on public.decks;
create trigger trg_decks_updated_at before update on public.decks
for each row execute function public.touch_updated_at();

drop trigger if exists trg_progress_updated_at on public.progress;
create trigger trg_progress_updated_at before update on public.progress
for each row execute function public.touch_updated_at();

drop trigger if exists trg_usage_updated_at on public.user_usage;
create trigger trg_usage_updated_at before update on public.user_usage
for each row execute function public.touch_updated_at();

drop trigger if exists trg_resources_updated_at on public.resources;
create trigger trg_resources_updated_at before update on public.resources
for each row execute function public.touch_updated_at();

-- Automatically create a public profile whenever Auth creates a user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, gender)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'name',''), 'Người học'),
    case when new.raw_user_meta_data ->> 'gender' in ('male','female') then new.raw_user_meta_data ->> 'gender' else 'female' end
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Admin check helper. It is security definer so RLS on profiles does not recursively call itself.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and status = 'active'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.is_active_account()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and status = 'active'
      and (role = 'admin' or expires_at is null or expires_at > now())
  );
$$;

revoke all on function public.is_active_account() from public;
grant execute on function public.is_active_account() to anon, authenticated;

-- Users may edit only harmless profile fields from the browser.
-- role/status/expires_at/email remain Admin/server-controlled.
create or replace function public.guard_profile_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = old.id and not public.is_admin() then
    new.id = old.id;
    new.email = old.email;
    new.role = old.role;
    new.status = old.status;
    new.expires_at = old.expires_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_profile_fields on public.profiles;
create trigger trg_guard_profile_fields
before update on public.profiles
for each row execute function public.guard_profile_privileged_fields();

-- RLS
alter table public.profiles enable row level security;
alter table public.decks enable row level security;
alter table public.progress enable row level security;
alter table public.study_sessions enable row level security;
alter table public.user_usage enable row level security;
alter table public.resources enable row level security;
alter table public.terms_acceptances enable row level security;

-- Reset app policies so the script can be rerun safely.
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname
           from pg_policies
           where schemaname = 'public'
             and tablename in ('profiles','decks','progress','study_sessions','user_usage','resources','terms_acceptances')
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- Profiles: a user reads/edits own profile; Admin reads/edits all.
create policy profiles_select_self_or_admin on public.profiles
for select to authenticated
using (id = auth.uid() or public.is_admin());

create policy profiles_update_self_or_admin on public.profiles
for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- Decks: everyone signed in can read published decks; Admin manages all.
create policy decks_select_signed_in on public.decks
for select to authenticated
using ((is_published = true and public.is_active_account()) or public.is_admin());

create policy decks_insert_admin on public.decks
for insert to authenticated
with check (public.is_admin());

create policy decks_update_admin on public.decks
for update to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy decks_delete_admin on public.decks
for delete to authenticated
using (public.is_admin());

-- Progress: users own their progress; Admin can inspect everything.
create policy progress_select_own_or_admin on public.progress
for select to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy progress_insert_own_or_admin on public.progress
for insert to authenticated
with check ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy progress_update_own_or_admin on public.progress
for update to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin())
with check ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy progress_delete_own_or_admin on public.progress
for delete to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

-- Study sessions: own rows or Admin; users may create their own session rows.
create policy sessions_select_own_or_admin on public.study_sessions
for select to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy sessions_insert_own on public.study_sessions
for insert to authenticated
with check (user_id = auth.uid() and public.is_active_account());

create policy sessions_delete_admin on public.study_sessions
for delete to authenticated
using (public.is_admin());

-- Usage: own usage or Admin.
create policy usage_select_own_or_admin on public.user_usage
for select to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy usage_insert_own_or_admin on public.user_usage
for insert to authenticated
with check ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy usage_update_own_or_admin on public.user_usage
for update to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin())
with check ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

-- Resources: signed-in users see published resources; Admin manages all.
create policy resources_select_signed_in on public.resources
for select to authenticated
using ((is_published = true and public.is_active_account()) or public.is_admin());

create policy resources_insert_admin on public.resources
for insert to authenticated
with check (public.is_admin());

create policy resources_update_admin on public.resources
for update to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy resources_delete_admin on public.resources
for delete to authenticated
using (public.is_admin());

-- Terms: user can record/view own acceptance, Admin can audit all.
create policy terms_select_own_or_admin on public.terms_acceptances
for select to authenticated
using ((user_id = auth.uid() and public.is_active_account()) or public.is_admin());

create policy terms_insert_own on public.terms_acceptances
for insert to authenticated
with check (user_id = auth.uid() and public.is_active_account());

grant select on public.profiles to authenticated;
grant update on public.profiles to authenticated;
grant select, insert, update, delete on public.decks to authenticated;
grant select, insert, update, delete on public.progress to authenticated;
grant select, insert, delete on public.study_sessions to authenticated;
grant select, insert, update on public.user_usage to authenticated;
grant select, insert, update, delete on public.resources to authenticated;
grant select, insert on public.terms_acceptances to authenticated;

-- Starter content: only if the table is empty.
do $$
declare did uuid;
begin
  if not exists (select 1 from public.decks) then
    insert into public.decks (name, cards, sort_order)
    values ('Bộ thẻ mẫu', jsonb_build_array(
      jsonb_build_object('id', encode(gen_random_bytes(8),'hex'), 'q','Thủ đô của Việt Nam là gì?', 'a','Hà Nội'),
      jsonb_build_object('id', encode(gen_random_bytes(8),'hex'), 'q','2 + 2 × 3 = ?', 'a','8'),
      jsonb_build_object('id', encode(gen_random_bytes(8),'hex'), 'q','Photosynthesis nghĩa là gì?', 'a','Quang hợp')
    ), 0)
    returning id into did;
  end if;
end $$;

-- ONE-TIME ADMIN SETUP:
-- 1) Create the admin account in Supabase Authentication > Users.
--    Use the Admin email configured in the project and the password you choose.
--    To keep the previously requested password, you may set it to: hzhzhuyhuy
-- 2) Then run, replacing the email with your Admin email:
-- update public.profiles set role='admin', status='active', expires_at=null
-- where email='huynhgiahuys3883@gmail.com';
