-- ============================================================
-- KEUANGAN KITA — Supabase schema, functions, grants, dan RLS
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 50),
  invite_code text not null unique check (char_length(invite_code) = 12),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id)
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  type text not null check (type in ('income', 'outcome')),
  amount bigint not null check (amount > 0),
  date date not null,
  category text not null check (char_length(category) between 1 and 50),
  source text check (source is null or source in ('husband', 'wife', 'savings', 'education')),
  description text not null default '' check (char_length(description) <= 100),
  husband_allocation bigint not null default 0 check (husband_allocation >= 0),
  wife_allocation bigint not null default 0 check (wife_allocation >= 0),
  savings_allocation bigint not null default 0 check (savings_allocation >= 0),
  education_allocation bigint not null default 0 check (education_allocation >= 0),
  created_at timestamptz not null default now(),
  constraint transaction_allocation_is_valid check (
    (
      type = 'income'
      and source is null
      and husband_allocation + wife_allocation + savings_allocation + education_allocation = amount
    )
    or
    (
      type = 'outcome'
      and source is not null
      and husband_allocation = 0
      and wife_allocation = 0
      and savings_allocation = 0
      and education_allocation = 0
    )
  )
);

create table if not exists public.assets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  asset_type text not null check (char_length(asset_type) between 1 and 40),
  name text not null check (char_length(name) between 1 and 80),
  quantity numeric(18, 2) not null default 1 check (quantity > 0),
  unit text not null default 'unit' check (char_length(unit) between 1 and 20),
  purchase_value bigint not null default 0 check (purchase_value >= 0),
  current_value bigint not null check (current_value >= 0),
  notes text not null default '' check (char_length(notes) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists household_members_user_id_idx
  on public.household_members(user_id);
create index if not exists transactions_household_date_idx
  on public.transactions(household_id, date desc);
create index if not exists assets_household_idx
  on public.assets(household_id);

-- Helper ini mencegah policy household_members menjadi rekursif.
create or replace function public.is_household_member(target_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members as member
    where member.household_id = target_household_id
      and member.user_id = (select auth.uid())
  );
$$;

-- Pengguna pertama membuat household dan otomatis menjadi owner.
create or replace function public.create_household(household_name text)
returns table(created_household_id uuid, created_invite_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  new_household_id uuid := gen_random_uuid();
  new_invite_code text;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  if exists (
    select 1 from public.household_members where user_id = current_user_id
  ) then
    raise exception 'User already belongs to a household';
  end if;

  loop
    new_invite_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (
      select 1 from public.households where invite_code = new_invite_code
    );
  end loop;

  insert into public.households (id, name, invite_code, created_by)
  values (new_household_id, trim(household_name), new_invite_code, current_user_id);

  insert into public.household_members (household_id, user_id, role)
  values (new_household_id, current_user_id, 'owner');

  return query select new_household_id, new_invite_code;
end;
$$;

-- Pasangan bergabung hanya jika mengetahui kode undangan.
create or replace function public.join_household(invitation_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_household_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  if exists (
    select 1 from public.household_members where user_id = current_user_id
  ) then
    raise exception 'User already belongs to a household';
  end if;

  select id
  into target_household_id
  from public.households
  where invite_code = upper(trim(invitation_code));

  if target_household_id is null then
    raise exception 'Invitation code not found';
  end if;

  -- Mengunci household selama pengecekan agar dua permintaan bersamaan
  -- tidak dapat membuat anggota ketiga.
  perform 1
  from public.households
  where id = target_household_id
  for update;

  if (
    select count(*)
    from public.household_members
    where household_id = target_household_id
  ) >= 2 then
    raise exception 'Household already has two members';
  end if;

  insert into public.household_members (household_id, user_id, role)
  values (target_household_id, current_user_id, 'member');

  return target_household_id;
end;
$$;

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.transactions enable row level security;
alter table public.assets enable row level security;

drop policy if exists "Members can read their household" on public.households;
create policy "Members can read their household"
on public.households
for select
to authenticated
using ((select public.is_household_member(id)));

drop policy if exists "Members can read household membership" on public.household_members;
create policy "Members can read household membership"
on public.household_members
for select
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_household_member(household_id))
);

drop policy if exists "Members can read transactions" on public.transactions;
create policy "Members can read transactions"
on public.transactions
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can add transactions" on public.transactions;
create policy "Members can add transactions"
on public.transactions
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and (select public.is_household_member(household_id))
);

drop policy if exists "Members can update transactions" on public.transactions;
create policy "Members can update transactions"
on public.transactions
for update
to authenticated
using ((select public.is_household_member(household_id)))
with check ((select public.is_household_member(household_id)));

drop policy if exists "Members can delete transactions" on public.transactions;
create policy "Members can delete transactions"
on public.transactions
for delete
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read assets" on public.assets;
create policy "Members can read assets"
on public.assets
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can add assets" on public.assets;
create policy "Members can add assets"
on public.assets
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and (select public.is_household_member(household_id))
);

drop policy if exists "Members can update assets" on public.assets;
create policy "Members can update assets"
on public.assets
for update
to authenticated
using ((select public.is_household_member(household_id)))
with check ((select public.is_household_member(household_id)));

drop policy if exists "Members can delete assets" on public.assets;
create policy "Members can delete assets"
on public.assets
for delete
to authenticated
using ((select public.is_household_member(household_id)));

-- Least-privilege grants untuk Data API.
revoke all on public.households from public, anon, authenticated;
revoke all on public.household_members from public, anon, authenticated;
revoke all on public.transactions from public, anon, authenticated;
revoke all on public.assets from public, anon, authenticated;

grant select on public.households to authenticated;
grant select on public.household_members to authenticated;
grant select, insert, update, delete on public.transactions to authenticated;
grant select, insert, update, delete on public.assets to authenticated;

revoke execute on function public.is_household_member(uuid) from public, anon;
revoke execute on function public.create_household(text) from public, anon;
revoke execute on function public.join_household(text) from public, anon;

grant execute on function public.is_household_member(uuid) to authenticated;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.join_household(text) to authenticated;
