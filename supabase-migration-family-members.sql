-- ============================================================
-- KEUANGAN KITA — Anggota keluarga dinamis, role, dan saldo pribadi
-- Jalankan setelah supabase-migration-monthly-bills.sql.
-- Aman dijalankan ulang.
-- ============================================================

begin;

create table if not exists public.household_member_profiles (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null,
  system_role text not null default 'member' check (system_role in ('owner', 'member')),
  family_role text not null default 'None' check (char_length(btrim(family_role)) between 1 and 30),
  email text not null check (char_length(email) between 3 and 320),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  color_index smallint not null default 0 check (color_index between 0 and 7),
  is_active boolean not null default true,
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (household_id, user_id)
);

create index if not exists household_member_profiles_household_active_idx
  on public.household_member_profiles(household_id, is_active, joined_at);
create index if not exists household_member_profiles_user_idx
  on public.household_member_profiles(user_id, is_active);

insert into public.household_member_profiles (
  household_id, user_id, system_role, family_role, email, display_name,
  color_index, is_active, joined_at
)
select
  member.household_id,
  member.user_id,
  member.role,
  case when member.role = 'owner' then 'Suami' else 'Istri' end,
  member.email,
  member.display_name,
  (row_number() over (partition by member.household_id order by member.joined_at, member.user_id) - 1)::smallint % 8,
  true,
  member.joined_at
from public.household_members as member
on conflict (household_id, user_id) do update
set system_role = excluded.system_role,
    email = excluded.email,
    display_name = excluded.display_name,
    is_active = true,
    removed_at = null;

create or replace function public.sync_household_member_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_color smallint;
begin
  if tg_op = 'DELETE' then
    update public.household_member_profiles
    set is_active = false,
        removed_at = now()
    where household_id = old.household_id
      and user_id = old.user_id;
    return old;
  end if;

  select (count(*) % 8)::smallint
  into next_color
  from public.household_member_profiles
  where household_id = new.household_id;

  insert into public.household_member_profiles (
    household_id, user_id, system_role, family_role, email, display_name,
    color_index, is_active, joined_at, removed_at
  ) values (
    new.household_id, new.user_id, new.role, 'None', new.email,
    new.display_name, next_color, true, new.joined_at, null
  )
  on conflict (household_id, user_id) do update
  set system_role = excluded.system_role,
      email = excluded.email,
      display_name = excluded.display_name,
      is_active = true,
      removed_at = null;

  return new;
end;
$$;

drop trigger if exists sync_household_member_profile_trigger on public.household_members;
create trigger sync_household_member_profile_trigger
after insert or update or delete on public.household_members
for each row execute function public.sync_household_member_profile();

create or replace function public.is_household_master(target_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.households as household
    left join public.household_members as member
      on member.household_id = household.id
     and member.user_id = (select auth.uid())
    where household.id = target_household_id
      and member.user_id is not null
      and (household.created_by = (select auth.uid()) or member.role = 'owner')
  );
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
  if exists (select 1 from public.household_members where user_id = current_user_id) then
    raise exception 'User already belongs to a household';
  end if;

  select id into target_household_id
  from public.households
  where invite_code = upper(trim(invitation_code));

  if target_household_id is null then
    raise exception 'Invitation code not found';
  end if;

  perform 1 from public.households where id = target_household_id for update;
  if (select count(*) from public.household_members where household_id = target_household_id) >= 8 then
    raise exception 'Household already has eight active members';
  end if;

  insert into public.household_members (household_id, user_id, role)
  values (target_household_id, current_user_id, 'member');
  return target_household_id;
end;
$$;

create or replace function public.member_allocations_are_valid(allocations jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(coalesce(allocations, '{}'::jsonb)) = 'object'
    and not exists (
      select 1
      from jsonb_each(coalesce(allocations, '{}'::jsonb)) as entry(key, value)
      where entry.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
         or jsonb_typeof(entry.value) <> 'number'
         or (entry.value #>> '{}')::numeric < 0
         or trunc((entry.value #>> '{}')::numeric) <> (entry.value #>> '{}')::numeric
         or (entry.value #>> '{}')::numeric > 9223372036854775807
    );
$$;

create or replace function public.member_allocations_total(allocations jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum((entry.value #>> '{}')::numeric), 0)::bigint
  from jsonb_each(coalesce(allocations, '{}'::jsonb)) as entry(key, value);
$$;

alter table public.transactions
  add column if not exists member_allocations jsonb not null default '{}'::jsonb,
  add column if not exists source_member_id uuid;

alter table public.transactions drop constraint if exists transactions_source_check;
alter table public.transactions drop constraint if exists transaction_allocation_is_valid;
alter table public.transactions drop constraint if exists transaction_member_allocations_check;
alter table public.transactions
  add constraint transactions_source_check
  check (source is null or source in ('husband', 'wife', 'member', 'savings', 'wife_savings', 'education'));
alter table public.transactions
  add constraint transaction_member_allocations_check
  check (public.member_allocations_are_valid(member_allocations));
alter table public.transactions
  add constraint transaction_allocation_is_valid check (
    (
      type = 'income'
      and source is null
      and source_member_id is null
      and husband_allocation + wife_allocation + savings_allocation
        + wife_savings_allocation + education_allocation
        + public.member_allocations_total(member_allocations) = amount
    )
    or
    (
      type = 'outcome'
      and source is not null
      and ((source = 'member' and source_member_id is not null) or (source <> 'member' and source_member_id is null))
      and husband_allocation = 0
      and wife_allocation = 0
      and savings_allocation = 0
      and wife_savings_allocation = 0
      and education_allocation = 0
      and public.member_allocations_total(member_allocations) = 0
    )
  );

alter table public.balance_transfers
  add column if not exists from_member_id uuid,
  add column if not exists to_member_id uuid;
alter table public.balance_transfers drop constraint if exists balance_transfers_from_balance_check;
alter table public.balance_transfers drop constraint if exists balance_transfers_to_balance_check;
alter table public.balance_transfers drop constraint if exists balance_transfer_different_destination;
alter table public.balance_transfers drop constraint if exists balance_transfer_member_fields_check;
alter table public.balance_transfers
  add constraint balance_transfers_from_balance_check
  check (from_balance in ('husband', 'wife', 'member', 'savings', 'wife_savings', 'education'));
alter table public.balance_transfers
  add constraint balance_transfers_to_balance_check
  check (to_balance in ('husband', 'wife', 'member', 'savings', 'wife_savings', 'education'));
alter table public.balance_transfers
  add constraint balance_transfer_member_fields_check check (
    ((from_balance = 'member' and from_member_id is not null) or (from_balance <> 'member' and from_member_id is null))
    and ((to_balance = 'member' and to_member_id is not null) or (to_balance <> 'member' and to_member_id is null))
  );
alter table public.balance_transfers
  add constraint balance_transfer_different_destination check (
    from_balance <> to_balance
    or (from_balance = 'member' and from_member_id is distinct from to_member_id)
  );

alter table public.balance_adjustments add column if not exists member_user_id uuid;
alter table public.balance_adjustments drop constraint if exists balance_adjustments_balance_key_check;
alter table public.balance_adjustments drop constraint if exists balance_adjustments_new_balance_check;
alter table public.balance_adjustments drop constraint if exists balance_adjustment_member_field_check;
alter table public.balance_adjustments
  add constraint balance_adjustments_balance_key_check
  check (balance_key in ('husband', 'wife', 'member', 'savings', 'wife_savings', 'education'));
alter table public.balance_adjustments
  add constraint balance_adjustment_member_field_check
  check ((balance_key = 'member' and member_user_id is not null) or (balance_key <> 'member' and member_user_id is null));
alter table public.balance_adjustments
  add constraint balance_adjustments_new_balance_check
  check (balance_key = 'member' or new_balance >= 0);

alter table public.monthly_bills drop constraint if exists monthly_bills_balance_key_check;
alter table public.monthly_bills
  add constraint monthly_bills_balance_key_check
  check (balance_key in ('husband', 'wife', 'member'));

create or replace function public.calculate_household_balance(
  target_household_id uuid,
  target_balance_key text,
  excluded_transaction_id uuid default null
)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  result_balance bigint := 0;
  target_user_id uuid;
  legacy_owner_id uuid;
  legacy_member_id uuid;
begin
  if target_balance_key like 'member:%' then
    begin
      target_user_id := split_part(target_balance_key, ':', 2)::uuid;
    exception when invalid_text_representation then
      raise exception 'Pos saldo anggota tidak valid';
    end;
  elsif target_balance_key not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;

  select profile.user_id into legacy_owner_id
  from public.household_member_profiles as profile
  where profile.household_id = target_household_id and profile.system_role = 'owner'
  order by profile.joined_at limit 1;

  select profile.user_id into legacy_member_id
  from public.household_member_profiles as profile
  where profile.household_id = target_household_id and profile.system_role = 'member'
  order by profile.joined_at limit 1;

  select coalesce(sum(
    case
      when target_user_id is not null and tx.type = 'income' then
        coalesce((tx.member_allocations ->> target_user_id::text)::bigint, 0)
        + case when target_user_id = legacy_owner_id then tx.husband_allocation else 0 end
        + case when target_user_id = legacy_member_id then tx.wife_allocation else 0 end
      when target_user_id is not null and tx.type = 'outcome' and tx.source = 'member' and tx.source_member_id = target_user_id then -tx.amount
      when target_user_id = legacy_owner_id and tx.type = 'outcome' and tx.source = 'husband' then -tx.amount
      when target_user_id = legacy_member_id and tx.type = 'outcome' and tx.source = 'wife' then -tx.amount
      when target_user_id is null and tx.type = 'income' and target_balance_key = 'husband' then tx.husband_allocation
      when target_user_id is null and tx.type = 'income' and target_balance_key = 'wife' then tx.wife_allocation
      when target_user_id is null and tx.type = 'income' and target_balance_key = 'savings' then tx.savings_allocation
      when target_user_id is null and tx.type = 'income' and target_balance_key = 'wife_savings' then tx.wife_savings_allocation
      when target_user_id is null and tx.type = 'income' and target_balance_key = 'education' then tx.education_allocation
      when target_user_id is null and tx.type = 'outcome' and tx.source = target_balance_key then -tx.amount
      else 0
    end
  ), 0)::bigint
  into result_balance
  from public.transactions as tx
  where tx.household_id = target_household_id
    and (excluded_transaction_id is null or tx.id <> excluded_transaction_id);

  select result_balance + coalesce(sum(
    case
      when target_user_id is not null and bt.to_balance = 'member' and bt.to_member_id = target_user_id then bt.amount
      when target_user_id is not null and bt.from_balance = 'member' and bt.from_member_id = target_user_id then -bt.amount
      when target_user_id = legacy_owner_id and bt.to_balance = 'husband' then bt.amount
      when target_user_id = legacy_owner_id and bt.from_balance = 'husband' then -bt.amount
      when target_user_id = legacy_member_id and bt.to_balance = 'wife' then bt.amount
      when target_user_id = legacy_member_id and bt.from_balance = 'wife' then -bt.amount
      when target_user_id is null and bt.to_balance = target_balance_key then bt.amount
      when target_user_id is null and bt.from_balance = target_balance_key then -bt.amount
      else 0
    end
  ), 0)::bigint
  into result_balance
  from public.balance_transfers as bt
  where bt.household_id = target_household_id;

  select result_balance + coalesce(sum(
    case
      when target_user_id is not null and ba.balance_key = 'member' and ba.member_user_id = target_user_id then ba.delta
      when target_user_id = legacy_owner_id and ba.balance_key = 'husband' then ba.delta
      when target_user_id = legacy_member_id and ba.balance_key = 'wife' then ba.delta
      when target_user_id is null and ba.balance_key = target_balance_key then ba.delta
      else 0
    end
  ), 0)::bigint
  into result_balance
  from public.balance_adjustments as ba
  where ba.household_id = target_household_id;

  return result_balance;
end;
$$;

create or replace function public.validate_transaction_member_access()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.type = 'income' and exists (
    select 1
    from jsonb_object_keys(new.member_allocations) as allocation(user_id)
    where not exists (
      select 1 from public.household_member_profiles as profile
      where profile.household_id = new.household_id
        and profile.user_id = allocation.user_id::uuid
        and profile.is_active
    )
  ) then
    raise exception 'Pembagian income hanya dapat diberikan kepada anggota aktif';
  end if;

  if new.type = 'outcome' and new.source = 'member' then
    if not exists (
      select 1 from public.household_member_profiles as profile
      where profile.household_id = new.household_id
        and profile.user_id = new.source_member_id
        and profile.is_active
    ) then
      raise exception 'Sumber saldo anggota tidak ditemukan';
    end if;
    if new.source_member_id <> auth.uid() and not public.is_household_master(new.household_id) then
      raise exception 'Hanya room master yang dapat memakai saldo anggota lain';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists validate_transaction_member_access_trigger on public.transactions;
create trigger validate_transaction_member_access_trigger
before insert or update on public.transactions
for each row execute function public.validate_transaction_member_access();

create or replace function public.prevent_negative_household_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_household_id uuid;
  excluded_id uuid;
  balance_key text;
  projected_balance bigint;
begin
  affected_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  if tg_op = 'UPDATE' and old.household_id <> new.household_id then
    raise exception 'Household transaksi tidak dapat dipindahkan';
  end if;

  perform 1 from public.households where id = affected_household_id for update;
  excluded_id := case when tg_op in ('UPDATE', 'DELETE') then old.id else null end;

  foreach balance_key in array array['savings', 'wife_savings', 'education'] loop
    projected_balance := public.calculate_household_balance(affected_household_id, balance_key, excluded_id);
    if tg_op in ('INSERT', 'UPDATE') then
      if new.type = 'income' then
        projected_balance := projected_balance + case balance_key
          when 'savings' then new.savings_allocation
          when 'wife_savings' then new.wife_savings_allocation
          when 'education' then new.education_allocation
          else 0 end;
      elsif new.source = balance_key then
        projected_balance := projected_balance - new.amount;
      end if;
    end if;
    if projected_balance < 0 then
      raise exception 'Saldo % tidak mencukupi', balance_key;
    end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.create_balance_transfer(
  p_from_balance text,
  p_to_balance text,
  p_amount bigint,
  p_date date,
  p_notes text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  member_household_id uuid;
  from_key text := p_from_balance;
  to_key text := p_to_balance;
  from_member uuid;
  to_member uuid;
  current_balance bigint;
  new_transfer_id uuid;
begin
  if current_user_id is null then raise exception 'Authentication required'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nominal transfer harus lebih dari nol'; end if;
  if p_date is null then raise exception 'Tanggal transfer wajib diisi'; end if;
  if char_length(coalesce(p_notes, '')) > 120 then raise exception 'Catatan maksimal 120 karakter'; end if;

  select member.household_id into member_household_id
  from public.household_members as member where member.user_id = current_user_id;
  if member_household_id is null then raise exception 'Household member not found'; end if;

  if from_key like 'member:%' then
    from_member := split_part(from_key, ':', 2)::uuid; from_key := 'member';
  end if;
  if to_key like 'member:%' then
    to_member := split_part(to_key, ':', 2)::uuid; to_key := 'member';
  end if;
  if from_key not in ('member', 'savings', 'wife_savings', 'education')
     or to_key not in ('member', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if from_key = to_key and from_member is not distinct from to_member then
    raise exception 'Pos asal dan tujuan harus berbeda';
  end if;
  if from_key = 'member' and not exists (
    select 1 from public.household_member_profiles
    where household_id = member_household_id and user_id = from_member and is_active
  ) then raise exception 'Saldo anggota asal tidak ditemukan'; end if;
  if to_key = 'member' and not exists (
    select 1 from public.household_member_profiles
    where household_id = member_household_id and user_id = to_member and is_active
  ) then raise exception 'Saldo anggota tujuan tidak ditemukan'; end if;
  if from_key = 'member' and from_member <> current_user_id
     and not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat mentransfer saldo anggota lain';
  end if;

  perform 1 from public.households where id = member_household_id for update;
  current_balance := public.calculate_household_balance(member_household_id, p_from_balance);
  if from_key <> 'member' and current_balance < p_amount then
    raise exception 'Saldo sumber tidak mencukupi';
  end if;

  insert into public.balance_transfers (
    household_id, user_id, from_balance, from_member_id, to_balance, to_member_id,
    amount, date, notes
  ) values (
    member_household_id, current_user_id, from_key, from_member, to_key, to_member,
    p_amount, p_date, btrim(coalesce(p_notes, ''))
  ) returning id into new_transfer_id;
  return new_transfer_id;
end;
$$;

create or replace function public.adjust_household_balance(
  p_balance_key text,
  p_new_balance bigint,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  member_household_id uuid;
  stored_key text := p_balance_key;
  target_member uuid;
  old_balance bigint;
  new_adjustment_id uuid;
  clean_notes text := btrim(coalesce(p_notes, ''));
begin
  if current_user_id is null then raise exception 'Authentication required'; end if;
  select member.household_id into member_household_id
  from public.household_members as member where member.user_id = current_user_id;
  if member_household_id is null then raise exception 'Household member not found'; end if;

  if stored_key like 'member:%' then
    target_member := split_part(stored_key, ':', 2)::uuid; stored_key := 'member';
  end if;
  if stored_key not in ('member', 'savings', 'wife_savings', 'education') then raise exception 'Pos saldo tidak valid'; end if;
  if p_new_balance is null or (stored_key <> 'member' and p_new_balance < 0) then
    raise exception 'Saldo bersama, tabungan, dan pendidikan tidak boleh minus';
  end if;
  if char_length(clean_notes) not between 3 and 120 then raise exception 'Alasan penyesuaian harus 3 sampai 120 karakter'; end if;
  if stored_key = 'member' and not exists (
    select 1 from public.household_member_profiles
    where household_id = member_household_id and user_id = target_member and is_active
  ) then raise exception 'Saldo anggota tidak ditemukan'; end if;
  if stored_key = 'member' and target_member <> current_user_id
     and not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat menyesuaikan saldo anggota lain';
  end if;

  perform 1 from public.households where id = member_household_id for update;
  old_balance := public.calculate_household_balance(member_household_id, p_balance_key);
  if old_balance = p_new_balance then raise exception 'Saldo baru sama dengan saldo saat ini'; end if;

  insert into public.balance_adjustments (
    household_id, user_id, balance_key, member_user_id,
    previous_balance, new_balance, delta, notes
  ) values (
    member_household_id, current_user_id, stored_key, target_member,
    old_balance, p_new_balance, p_new_balance - old_balance, clean_notes
  ) returning id into new_adjustment_id;
  return new_adjustment_id;
end;
$$;

create or replace function public.set_member_family_role(target_user_id uuid, new_family_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_household_id uuid;
  clean_role text := btrim(new_family_role);
begin
  select household_id into member_household_id
  from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then
    raise exception 'Only the room master can change family roles';
  end if;
  if clean_role is null or char_length(clean_role) not between 1 and 30 then
    raise exception 'Role must contain 1 to 30 characters';
  end if;

  update public.household_member_profiles
  set family_role = clean_role
  where household_id = member_household_id and user_id = target_user_id and is_active;
  if not found then raise exception 'Active household member not found'; end if;

  insert into public.audit_logs (household_id, user_id, action, entity_type, entity_id, summary, details)
  values (member_household_id, auth.uid(), 'update', 'family_member', target_user_id,
    'Role anggota diubah', jsonb_build_object('family_role', clean_role));
end;
$$;

create or replace function public.remove_household_member(target_user_id uuid, confirmation_text text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_household_id uuid;
  target_name text;
  target_balance bigint;
begin
  select household_id into member_household_id
  from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then
    raise exception 'Only the room master can remove members';
  end if;
  if target_user_id = auth.uid() then raise exception 'Room master cannot remove their own account'; end if;
  if confirmation_text is distinct from 'HAPUS' then raise exception 'Type HAPUS to confirm'; end if;

  select display_name into target_name
  from public.household_member_profiles
  where household_id = member_household_id and user_id = target_user_id and is_active;
  if target_name is null then raise exception 'Active household member not found'; end if;

  perform 1 from public.households where id = member_household_id for update;
  target_balance := public.calculate_household_balance(member_household_id, 'member:' || target_user_id::text);
  if target_balance <> 0 then
    raise exception 'Saldo anggota harus Rp0 sebelum akses dihapus. Transfer atau sesuaikan saldo terlebih dahulu.';
  end if;

  insert into public.audit_logs (household_id, user_id, action, entity_type, entity_id, summary, details)
  values (member_household_id, auth.uid(), 'delete', 'family_member', target_user_id,
    'Akses anggota ' || target_name || ' dihapus', jsonb_build_object('display_name', target_name, 'history_preserved', true));

  delete from public.household_members
  where household_id = member_household_id and user_id = target_user_id;
end;
$$;

create or replace function public.can_manage_household_balance(target_household_id uuid, target_balance_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.household_members as member
    where member.household_id = target_household_id
      and member.user_id = (select auth.uid())
      and (
        target_balance_key = 'member'
        or (member.role = 'owner' and target_balance_key = 'husband')
        or (member.role = 'member' and target_balance_key = 'wife')
      )
  );
$$;

create or replace function public.can_manage_monthly_bill(target_bill_id uuid, target_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.monthly_bills as bill
    join public.household_members as member
      on member.household_id = bill.household_id
     and member.user_id = (select auth.uid())
    where bill.id = target_bill_id
      and bill.household_id = target_household_id
      and bill.owner_user_id = (select auth.uid())
  );
$$;

alter table public.household_member_profiles enable row level security;
drop policy if exists "Members can read household profiles" on public.household_member_profiles;
create policy "Members can read household profiles"
on public.household_member_profiles for select to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can update transactions" on public.transactions;
create policy "Members can update transactions"
on public.transactions for update to authenticated
using (
  (select public.is_household_member(household_id))
  and (user_id = (select auth.uid()) or (select public.is_household_master(household_id)))
)
with check (
  (select public.is_household_member(household_id))
  and (user_id = (select auth.uid()) or (select public.is_household_master(household_id)))
);

drop policy if exists "Members can delete transactions" on public.transactions;
create policy "Members can delete transactions"
on public.transactions for delete to authenticated
using (
  (select public.is_household_member(household_id))
  and (user_id = (select auth.uid()) or (select public.is_household_master(household_id)))
);

do $$
declare constraint_item record;
begin
  for constraint_item in
    select conname from pg_catalog.pg_constraint
    where conrelid = 'public.audit_logs'::regclass
      and contype = 'c'
      and pg_catalog.pg_get_constraintdef(oid) ilike '%entity_type%'
  loop
    execute format('alter table public.audit_logs drop constraint %I', constraint_item.conname);
  end loop;
end;
$$;
alter table public.audit_logs
  add constraint audit_logs_entity_type_check
  check (entity_type in ('transaction', 'asset', 'transfer', 'adjustment', 'monthly_bill', 'bill_payment', 'family_member'));

revoke all on public.household_member_profiles from public, anon, authenticated;
grant select on public.household_member_profiles to authenticated;

revoke execute on function public.sync_household_member_profile() from public, anon, authenticated;
revoke execute on function public.is_household_master(uuid) from public, anon;
revoke execute on function public.member_allocations_are_valid(jsonb) from public, anon, authenticated;
revoke execute on function public.member_allocations_total(jsonb) from public, anon, authenticated;
revoke execute on function public.validate_transaction_member_access() from public, anon, authenticated;
revoke execute on function public.set_member_family_role(uuid, text) from public, anon;
revoke execute on function public.remove_household_member(uuid, text) from public, anon;

grant execute on function public.is_household_master(uuid) to authenticated;
grant execute on function public.member_allocations_are_valid(jsonb) to authenticated;
grant execute on function public.member_allocations_total(jsonb) to authenticated;
grant execute on function public.set_member_family_role(uuid, text) to authenticated;
grant execute on function public.remove_household_member(uuid, text) to authenticated;

commit;
notify pgrst, 'reload schema';
