-- ============================================================
-- KEUANGAN KITA — Nama pengguna untuk profil dan riwayat
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- Nama awal diambil dari email sebelum tanda @.
-- ============================================================

begin;

alter table public.household_members
  add column if not exists email text;

update public.household_members as member
set email = lower(auth_user.email)
from auth.users as auth_user
where auth_user.id = member.user_id
  and member.email is null;

alter table public.household_members
  drop constraint if exists household_members_email_check;

alter table public.household_members
  add constraint household_members_email_check
  check (char_length(email) between 3 and 320);

alter table public.household_members
  alter column email set not null;

alter table public.household_members
  add column if not exists display_name text;

update public.household_members
set display_name = left(split_part(email, '@', 1), 40)
where display_name is null or btrim(display_name) = '';

alter table public.household_members
  drop constraint if exists household_members_display_name_check;

alter table public.household_members
  add constraint household_members_display_name_check
  check (char_length(btrim(display_name)) between 1 and 40);

alter table public.household_members
  alter column display_name set not null;

create or replace function public.set_household_member_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select lower(auth_user.email)
  into new.email
  from auth.users as auth_user
  where auth_user.id = new.user_id;

  if new.email is null then
    raise exception 'User email not found';
  end if;

  if new.display_name is null or btrim(new.display_name) = '' then
    new.display_name := left(split_part(new.email, '@', 1), 40);
  end if;

  return new;
end;
$$;

create or replace function public.update_own_display_name(new_display_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_name text := btrim(new_display_name);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if clean_name is null or char_length(clean_name) not between 1 and 40 then
    raise exception 'Name must contain 1 to 40 characters';
  end if;

  update public.household_members
  set display_name = clean_name
  where user_id = auth.uid();

  if not found then
    raise exception 'Household member not found';
  end if;
end;
$$;

revoke execute on function public.set_household_member_email() from public, anon, authenticated;
revoke execute on function public.update_own_display_name(text) from public, anon;
grant execute on function public.update_own_display_name(text) to authenticated;

commit;
