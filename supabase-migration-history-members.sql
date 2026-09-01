-- ============================================================
-- KEUANGAN KITA — Identitas pencatat untuk riwayat transaksi
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- Email hanya dapat dibaca oleh anggota household yang sama.
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

  return new;
end;
$$;

drop trigger if exists set_household_member_email_trigger on public.household_members;
create trigger set_household_member_email_trigger
before insert or update of user_id on public.household_members
for each row execute function public.set_household_member_email();

revoke execute on function public.set_household_member_email() from public, anon, authenticated;

commit;
