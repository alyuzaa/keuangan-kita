-- ============================================================
-- KEUANGAN KITA v21 — Pos tabungan dinamis dan pengaturan room
-- Jalankan setelah supabase-migration-important-logs.sql.
-- Aman dijalankan ulang.
-- ============================================================

begin;

alter table public.households
  add column if not exists payday_enabled boolean not null default true,
  add column if not exists payday_day smallint not null default 10;
alter table public.households drop constraint if exists households_payday_day_check;
alter table public.households
  add constraint households_payday_day_check check (payday_day between 1 and 31);

create table if not exists public.savings_accounts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null,
  include_in_net_worth boolean not null default true,
  legacy_key text,
  is_archived boolean not null default false,
  sort_order smallint not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, household_id),
  unique (household_id, legacy_key),
  constraint savings_accounts_name_check check (char_length(btrim(name)) between 1 and 40),
  constraint savings_accounts_legacy_key_check check (legacy_key is null or legacy_key in ('savings', 'wife_savings', 'education')),
  constraint savings_accounts_sort_order_check check (sort_order >= 0)
);

create unique index if not exists savings_accounts_active_name_idx
  on public.savings_accounts(household_id, lower(btrim(name))) where not is_archived;
create index if not exists savings_accounts_household_order_idx
  on public.savings_accounts(household_id, is_archived, sort_order, created_at);

insert into public.savings_accounts (household_id, name, include_in_net_worth, legacy_key, sort_order, created_by)
select household.id, seed.name, seed.include_in_net_worth, seed.legacy_key, seed.sort_order, household.created_by
from public.households as household
cross join (values
  ('Tabungan bersama'::text, true, 'savings'::text, 0::smallint),
  ('Tabungan istri'::text, true, 'wife_savings'::text, 1::smallint),
  ('Pendidikan'::text, false, 'education'::text, 2::smallint)
) as seed(name, include_in_net_worth, legacy_key, sort_order)
on conflict (household_id, legacy_key) do nothing;

create or replace function public.seed_default_savings_accounts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.savings_accounts (household_id, name, include_in_net_worth, legacy_key, sort_order, created_by)
  values
    (new.id, 'Tabungan bersama', true, 'savings', 0, new.created_by),
    (new.id, 'Tabungan istri', true, 'wife_savings', 1, new.created_by),
    (new.id, 'Pendidikan', false, 'education', 2, new.created_by)
  on conflict (household_id, legacy_key) do nothing;
  return new;
end;
$$;

drop trigger if exists seed_default_savings_accounts_trigger on public.households;
create trigger seed_default_savings_accounts_trigger
after insert on public.households
for each row execute function public.seed_default_savings_accounts();

create or replace function public.touch_savings_account_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists touch_savings_account_updated_at_trigger on public.savings_accounts;
create trigger touch_savings_account_updated_at_trigger
before update on public.savings_accounts
for each row execute function public.touch_savings_account_updated_at();

alter table public.transactions
  add column if not exists savings_allocations jsonb not null default '{}'::jsonb,
  add column if not exists source_savings_id uuid;
alter table public.transactions drop constraint if exists transactions_source_savings_household_fkey;
alter table public.transactions
  add constraint transactions_source_savings_household_fkey
  foreign key (source_savings_id, household_id) references public.savings_accounts(id, household_id);

alter table public.transactions drop constraint if exists transactions_source_check;
alter table public.transactions drop constraint if exists transaction_allocation_is_valid;
alter table public.transactions drop constraint if exists transaction_savings_allocations_check;
alter table public.transactions
  add constraint transactions_source_check
  check (source is null or source in ('husband', 'wife', 'member', 'savings_account', 'savings', 'wife_savings', 'education'));
alter table public.transactions
  add constraint transaction_savings_allocations_check
  check (public.member_allocations_are_valid(savings_allocations));
alter table public.transactions
  add constraint transaction_allocation_is_valid check (
    (
      type = 'income'
      and source is null and source_member_id is null and source_savings_id is null
      and husband_allocation + wife_allocation + savings_allocation
        + wife_savings_allocation + education_allocation
        + public.member_allocations_total(member_allocations)
        + public.member_allocations_total(savings_allocations) = amount
    )
    or
    (
      type = 'outcome'
      and source is not null
      and ((source = 'member' and source_member_id is not null) or (source <> 'member' and source_member_id is null))
      and ((source = 'savings_account' and source_savings_id is not null) or (source <> 'savings_account' and source_savings_id is null))
      and husband_allocation = 0 and wife_allocation = 0 and savings_allocation = 0
      and wife_savings_allocation = 0 and education_allocation = 0
      and public.member_allocations_total(member_allocations) = 0
      and public.member_allocations_total(savings_allocations) = 0
    )
  );

alter table public.balance_transfers
  add column if not exists from_savings_account_id uuid,
  add column if not exists to_savings_account_id uuid;
alter table public.balance_transfers drop constraint if exists balance_transfers_from_savings_household_fkey;
alter table public.balance_transfers drop constraint if exists balance_transfers_to_savings_household_fkey;
alter table public.balance_transfers
  add constraint balance_transfers_from_savings_household_fkey
  foreign key (from_savings_account_id, household_id) references public.savings_accounts(id, household_id);
alter table public.balance_transfers
  add constraint balance_transfers_to_savings_household_fkey
  foreign key (to_savings_account_id, household_id) references public.savings_accounts(id, household_id);
alter table public.balance_transfers drop constraint if exists balance_transfers_from_balance_check;
alter table public.balance_transfers drop constraint if exists balance_transfers_to_balance_check;
alter table public.balance_transfers drop constraint if exists balance_transfer_different_destination;
alter table public.balance_transfers drop constraint if exists balance_transfer_member_fields_check;
alter table public.balance_transfers
  add constraint balance_transfers_from_balance_check
  check (from_balance in ('husband', 'wife', 'member', 'savings_account', 'savings', 'wife_savings', 'education'));
alter table public.balance_transfers
  add constraint balance_transfers_to_balance_check
  check (to_balance in ('husband', 'wife', 'member', 'savings_account', 'savings', 'wife_savings', 'education'));
alter table public.balance_transfers
  add constraint balance_transfer_member_fields_check check (
    ((from_balance = 'member' and from_member_id is not null) or (from_balance <> 'member' and from_member_id is null))
    and ((to_balance = 'member' and to_member_id is not null) or (to_balance <> 'member' and to_member_id is null))
    and ((from_balance = 'savings_account' and from_savings_account_id is not null) or (from_balance <> 'savings_account' and from_savings_account_id is null))
    and ((to_balance = 'savings_account' and to_savings_account_id is not null) or (to_balance <> 'savings_account' and to_savings_account_id is null))
  );
alter table public.balance_transfers
  add constraint balance_transfer_different_destination check (
    from_balance <> to_balance
    or (from_balance = 'member' and from_member_id is distinct from to_member_id)
    or (from_balance = 'savings_account' and from_savings_account_id is distinct from to_savings_account_id)
  );

alter table public.balance_adjustments add column if not exists savings_account_id uuid;
alter table public.balance_adjustments drop constraint if exists balance_adjustments_savings_household_fkey;
alter table public.balance_adjustments
  add constraint balance_adjustments_savings_household_fkey
  foreign key (savings_account_id, household_id) references public.savings_accounts(id, household_id);
alter table public.balance_adjustments drop constraint if exists balance_adjustments_balance_key_check;
alter table public.balance_adjustments drop constraint if exists balance_adjustments_new_balance_check;
alter table public.balance_adjustments drop constraint if exists balance_adjustment_member_field_check;
alter table public.balance_adjustments
  add constraint balance_adjustments_balance_key_check
  check (balance_key in ('husband', 'wife', 'member', 'savings_account', 'savings', 'wife_savings', 'education'));
alter table public.balance_adjustments
  add constraint balance_adjustment_member_field_check check (
    ((balance_key = 'member' and member_user_id is not null) or (balance_key <> 'member' and member_user_id is null))
    and ((balance_key = 'savings_account' and savings_account_id is not null) or (balance_key <> 'savings_account' and savings_account_id is null))
  );
alter table public.balance_adjustments
  add constraint balance_adjustments_new_balance_check
  check (balance_key = 'member' or new_balance >= 0);

create or replace function public.calculate_savings_account_balance(
  target_household_id uuid,
  target_account_id uuid,
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
  target_legacy_key text;
begin
  select legacy_key into target_legacy_key
  from public.savings_accounts
  where id = target_account_id and household_id = target_household_id;
  if not found then raise exception 'Pos tabungan tidak ditemukan'; end if;

  select coalesce(sum(
    case
      when tx.type = 'income' then
        coalesce((tx.savings_allocations ->> target_account_id::text)::bigint, 0)
        + case target_legacy_key
            when 'savings' then tx.savings_allocation
            when 'wife_savings' then tx.wife_savings_allocation
            when 'education' then tx.education_allocation
            else 0 end
      when tx.type = 'outcome' and tx.source = 'savings_account' and tx.source_savings_id = target_account_id then -tx.amount
      when tx.type = 'outcome' and target_legacy_key is not null and tx.source = target_legacy_key then -tx.amount
      else 0
    end
  ), 0)::bigint into result_balance
  from public.transactions as tx
  where tx.household_id = target_household_id
    and (excluded_transaction_id is null or tx.id <> excluded_transaction_id);

  select result_balance + coalesce(sum(
    case
      when bt.to_balance = 'savings_account' and bt.to_savings_account_id = target_account_id then bt.amount
      when bt.from_balance = 'savings_account' and bt.from_savings_account_id = target_account_id then -bt.amount
      when target_legacy_key is not null and bt.to_balance = target_legacy_key then bt.amount
      when target_legacy_key is not null and bt.from_balance = target_legacy_key then -bt.amount
      else 0
    end
  ), 0)::bigint into result_balance
  from public.balance_transfers as bt where bt.household_id = target_household_id;

  select result_balance + coalesce(sum(
    case
      when ba.balance_key = 'savings_account' and ba.savings_account_id = target_account_id then ba.delta
      when target_legacy_key is not null and ba.balance_key = target_legacy_key then ba.delta
      else 0
    end
  ), 0)::bigint into result_balance
  from public.balance_adjustments as ba where ba.household_id = target_household_id;

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
    select 1 from jsonb_object_keys(new.member_allocations) as allocation(user_id)
    where not exists (
      select 1 from public.household_member_profiles as profile
      where profile.household_id = new.household_id
        and profile.user_id = allocation.user_id::uuid and profile.is_active
    )
  ) then raise exception 'Pembagian income hanya dapat diberikan kepada anggota aktif'; end if;

  if new.type = 'income' then
    if tg_op = 'INSERT' and exists (
      select 1 from jsonb_object_keys(new.savings_allocations) as allocation(account_id)
      where not exists (
        select 1 from public.savings_accounts as account
        where account.household_id = new.household_id
          and account.id = allocation.account_id::uuid and not account.is_archived
      )
    ) then raise exception 'Pembagian income hanya dapat diberikan kepada tabungan aktif'; end if;
    if tg_op = 'UPDATE' and exists (
      select 1 from jsonb_object_keys(new.savings_allocations) as allocation(account_id)
      where not exists (
        select 1 from public.savings_accounts as account
        where account.household_id = new.household_id and account.id = allocation.account_id::uuid
          and (not account.is_archived or coalesce(new.savings_allocations ->> account.id::text, '0') = coalesce(old.savings_allocations ->> account.id::text, '0'))
      )
    ) then raise exception 'Pembagian pada tabungan yang diarsipkan tidak dapat diubah'; end if;
    if tg_op = 'INSERT' and exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.is_archived
        and case account.legacy_key
          when 'savings' then new.savings_allocation
          when 'wife_savings' then new.wife_savings_allocation
          when 'education' then new.education_allocation
          else 0 end > 0
    ) then raise exception 'Pembagian income hanya dapat diberikan kepada tabungan aktif'; end if;
    if tg_op = 'UPDATE' and exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.is_archived
        and case account.legacy_key
          when 'savings' then new.savings_allocation is distinct from old.savings_allocation
          when 'wife_savings' then new.wife_savings_allocation is distinct from old.wife_savings_allocation
          when 'education' then new.education_allocation is distinct from old.education_allocation
          else false end
    ) then raise exception 'Pembagian pada tabungan yang diarsipkan tidak dapat diubah'; end if;
  end if;

  if new.type = 'outcome' and new.source = 'member' then
    if not exists (
      select 1 from public.household_member_profiles as profile
      where profile.household_id = new.household_id
        and profile.user_id = new.source_member_id and profile.is_active
    ) then raise exception 'Sumber saldo anggota tidak ditemukan'; end if;
    if new.source_member_id <> auth.uid() and not public.is_household_master(new.household_id) then
      raise exception 'Hanya room master yang dapat memakai saldo anggota lain';
    end if;
  end if;

  if new.type = 'outcome' and new.source = 'savings_account' then
    if tg_op = 'INSERT' and not exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.id = new.source_savings_id and not account.is_archived
    ) then raise exception 'Sumber tabungan tidak ditemukan atau sudah diarsipkan'; end if;
    if tg_op = 'UPDATE' and not exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.id = new.source_savings_id
        and (not account.is_archived or (old.source = new.source and old.source_savings_id = new.source_savings_id and old.amount = new.amount))
    ) then raise exception 'Sumber tabungan yang diarsipkan tidak dapat diubah'; end if;
  end if;
  if new.type = 'outcome' and new.source in ('savings', 'wife_savings', 'education') then
    if tg_op = 'INSERT' and exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.legacy_key = new.source and account.is_archived
    ) then raise exception 'Sumber tabungan sudah diarsipkan'; end if;
    if tg_op = 'UPDATE' and exists (
      select 1 from public.savings_accounts as account
      where account.household_id = new.household_id and account.legacy_key = new.source and account.is_archived
        and (old.source is distinct from new.source or old.amount is distinct from new.amount)
    ) then raise exception 'Sumber tabungan yang diarsipkan tidak dapat diubah'; end if;
  end if;
  return new;
end;
$$;

create or replace function public.prevent_negative_household_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected_household_id uuid;
  excluded_id uuid;
  account record;
  projected_balance bigint;
begin
  affected_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  if tg_op = 'UPDATE' and old.household_id <> new.household_id then
    raise exception 'Household transaksi tidak dapat dipindahkan';
  end if;
  perform 1 from public.households where id = affected_household_id for update;
  excluded_id := case when tg_op in ('UPDATE', 'DELETE') then old.id else null end;

  for account in select id, legacy_key from public.savings_accounts where household_id = affected_household_id loop
    projected_balance := public.calculate_savings_account_balance(affected_household_id, account.id, excluded_id);
    if tg_op in ('INSERT', 'UPDATE') then
      if new.type = 'income' then
        projected_balance := projected_balance + coalesce((new.savings_allocations ->> account.id::text)::bigint, 0)
          + case account.legacy_key
              when 'savings' then new.savings_allocation
              when 'wife_savings' then new.wife_savings_allocation
              when 'education' then new.education_allocation
              else 0 end;
      elsif new.source = 'savings_account' and new.source_savings_id = account.id then
        projected_balance := projected_balance - new.amount;
      elsif account.legacy_key is not null and new.source = account.legacy_key then
        projected_balance := projected_balance - new.amount;
      end if;
    end if;
    if projected_balance < 0 then raise exception 'Saldo tabungan % tidak mencukupi', account.id; end if;
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
  from_savings uuid;
  to_savings uuid;
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

  if from_key like 'member:%' then from_member := split_part(from_key, ':', 2)::uuid; from_key := 'member'; end if;
  if to_key like 'member:%' then to_member := split_part(to_key, ':', 2)::uuid; to_key := 'member'; end if;
  if from_key like 'saving:%' then from_savings := split_part(from_key, ':', 2)::uuid; from_key := 'savings_account'; end if;
  if to_key like 'saving:%' then to_savings := split_part(to_key, ':', 2)::uuid; to_key := 'savings_account'; end if;
  if from_key not in ('member', 'savings_account', 'savings', 'wife_savings', 'education')
    or to_key not in ('member', 'savings_account', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if from_key = to_key and from_member is not distinct from to_member and from_savings is not distinct from to_savings then
    raise exception 'Pos asal dan tujuan harus berbeda';
  end if;
  if from_key = 'member' and not exists (
    select 1 from public.household_member_profiles where household_id = member_household_id and user_id = from_member and is_active
  ) then raise exception 'Saldo anggota asal tidak ditemukan'; end if;
  if to_key = 'member' and not exists (
    select 1 from public.household_member_profiles where household_id = member_household_id and user_id = to_member and is_active
  ) then raise exception 'Saldo anggota tujuan tidak ditemukan'; end if;
  if from_key = 'savings_account' and not exists (
    select 1 from public.savings_accounts where household_id = member_household_id and id = from_savings and not is_archived
  ) then raise exception 'Tabungan asal tidak ditemukan'; end if;
  if to_key = 'savings_account' and not exists (
    select 1 from public.savings_accounts where household_id = member_household_id and id = to_savings and not is_archived
  ) then raise exception 'Tabungan tujuan tidak ditemukan'; end if;
  if from_key = 'member' and from_member <> current_user_id and not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat mentransfer saldo anggota lain';
  end if;

  perform 1 from public.households where id = member_household_id for update;
  current_balance := case when from_key = 'savings_account'
    then public.calculate_savings_account_balance(member_household_id, from_savings)
    else public.calculate_household_balance(member_household_id, p_from_balance) end;
  if from_key <> 'member' and current_balance < p_amount then raise exception 'Saldo sumber tidak mencukupi'; end if;

  insert into public.balance_transfers (
    household_id, user_id, from_balance, from_member_id, from_savings_account_id,
    to_balance, to_member_id, to_savings_account_id, amount, date, notes
  ) values (
    member_household_id, current_user_id, from_key, from_member, from_savings,
    to_key, to_member, to_savings, p_amount, p_date, btrim(coalesce(p_notes, ''))
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
  target_savings uuid;
  old_balance bigint;
  new_adjustment_id uuid;
  clean_notes text := btrim(coalesce(p_notes, ''));
begin
  if current_user_id is null then raise exception 'Authentication required'; end if;
  select member.household_id into member_household_id
  from public.household_members as member where member.user_id = current_user_id;
  if member_household_id is null then raise exception 'Household member not found'; end if;
  if stored_key like 'member:%' then target_member := split_part(stored_key, ':', 2)::uuid; stored_key := 'member'; end if;
  if stored_key like 'saving:%' then target_savings := split_part(stored_key, ':', 2)::uuid; stored_key := 'savings_account'; end if;
  if stored_key not in ('member', 'savings_account', 'savings', 'wife_savings', 'education') then raise exception 'Pos saldo tidak valid'; end if;
  if p_new_balance is null or (stored_key <> 'member' and p_new_balance < 0) then raise exception 'Saldo tabungan tidak boleh minus'; end if;
  if char_length(clean_notes) not between 3 and 120 then raise exception 'Alasan penyesuaian harus 3 sampai 120 karakter'; end if;
  if stored_key = 'member' and not exists (
    select 1 from public.household_member_profiles where household_id = member_household_id and user_id = target_member and is_active
  ) then raise exception 'Saldo anggota tidak ditemukan'; end if;
  if stored_key = 'savings_account' and not exists (
    select 1 from public.savings_accounts where household_id = member_household_id and id = target_savings and not is_archived
  ) then raise exception 'Tabungan tidak ditemukan'; end if;
  if stored_key = 'member' and target_member <> current_user_id and not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat menyesuaikan saldo anggota lain';
  end if;
  perform 1 from public.households where id = member_household_id for update;
  old_balance := case when stored_key = 'savings_account'
    then public.calculate_savings_account_balance(member_household_id, target_savings)
    else public.calculate_household_balance(member_household_id, p_balance_key) end;
  if old_balance = p_new_balance then raise exception 'Saldo baru sama dengan saldo saat ini'; end if;
  insert into public.balance_adjustments (
    household_id, user_id, balance_key, member_user_id, savings_account_id,
    previous_balance, new_balance, delta, notes
  ) values (
    member_household_id, current_user_id, stored_key, target_member, target_savings,
    old_balance, p_new_balance, p_new_balance - old_balance, clean_notes
  ) returning id into new_adjustment_id;
  return new_adjustment_id;
end;
$$;

create or replace function public.save_savings_account(
  p_account_id uuid,
  p_name text,
  p_include_in_net_worth boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_household_id uuid;
  clean_name text := btrim(p_name);
  saved_id uuid;
  next_order smallint;
begin
  select household_id into member_household_id from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat mengatur tabungan';
  end if;
  if clean_name is null or char_length(clean_name) not between 1 and 40 then raise exception 'Nama tabungan harus 1 sampai 40 karakter'; end if;
  if p_account_id is null then
    if (select count(*) from public.savings_accounts where household_id = member_household_id and not is_archived) >= 12 then
      raise exception 'Maksimal 12 tabungan aktif';
    end if;
    select coalesce(max(sort_order), -1) + 1 into next_order from public.savings_accounts where household_id = member_household_id;
    insert into public.savings_accounts (household_id, name, include_in_net_worth, sort_order, created_by)
    values (member_household_id, clean_name, coalesce(p_include_in_net_worth, true), next_order, auth.uid())
    returning id into saved_id;
  else
    update public.savings_accounts
    set name = clean_name, include_in_net_worth = coalesce(p_include_in_net_worth, true)
    where id = p_account_id and household_id = member_household_id and not is_archived
    returning id into saved_id;
    if saved_id is null then raise exception 'Tabungan aktif tidak ditemukan'; end if;
  end if;
  return saved_id;
exception when unique_violation then
  raise exception 'Nama tabungan aktif sudah digunakan';
end;
$$;

create or replace function public.archive_savings_account(p_account_id uuid, confirmation_text text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_household_id uuid;
  current_balance bigint;
begin
  select household_id into member_household_id from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat menghapus tabungan';
  end if;
  if upper(btrim(coalesce(confirmation_text, ''))) <> 'HAPUS' then raise exception 'Ketik HAPUS untuk verifikasi'; end if;
  perform 1 from public.households where id = member_household_id for update;
  if not exists (
    select 1 from public.savings_accounts where id = p_account_id and household_id = member_household_id and not is_archived
  ) then raise exception 'Tabungan aktif tidak ditemukan'; end if;
  current_balance := public.calculate_savings_account_balance(member_household_id, p_account_id);
  if current_balance <> 0 then raise exception 'Saldo tabungan harus Rp0 sebelum dihapus'; end if;
  update public.savings_accounts set is_archived = true where id = p_account_id and household_id = member_household_id;
end;
$$;

create or replace function public.update_household_name(new_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare member_household_id uuid; clean_name text := btrim(new_name);
begin
  select household_id into member_household_id from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then raise exception 'Hanya room master yang dapat mengubah nama keluarga'; end if;
  if clean_name is null or char_length(clean_name) not between 1 and 50 then raise exception 'Nama keluarga harus 1 sampai 50 karakter'; end if;
  update public.households set name = clean_name where id = member_household_id;
end;
$$;

create or replace function public.update_household_payday(enabled boolean, salary_day smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare member_household_id uuid;
begin
  select household_id into member_household_id from public.household_members where user_id = auth.uid();
  if member_household_id is null or not public.is_household_master(member_household_id) then raise exception 'Hanya room master yang dapat mengatur tanggal gajian'; end if;
  if coalesce(salary_day, 0) not between 1 and 31 then raise exception 'Tanggal gajian harus antara 1 dan 31'; end if;
  update public.households set payday_enabled = coalesce(enabled, false), payday_day = salary_day where id = member_household_id;
end;
$$;

create or replace function public.write_finance_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  record_household_id uuid; record_user_id uuid; record_id uuid;
  record_action text; record_entity_type text; record_summary text; record_details jsonb;
begin
  if tg_table_name = 'transactions' and tg_op = 'UPDATE' then
    if old.type is not distinct from new.type and old.amount is not distinct from new.amount
      and old.date is not distinct from new.date and old.source is not distinct from new.source
      and old.source_member_id is not distinct from new.source_member_id
      and old.source_savings_id is not distinct from new.source_savings_id
      and old.husband_allocation is not distinct from new.husband_allocation
      and old.wife_allocation is not distinct from new.wife_allocation
      and old.savings_allocation is not distinct from new.savings_allocation
      and old.wife_savings_allocation is not distinct from new.wife_savings_allocation
      and old.education_allocation is not distinct from new.education_allocation
      and old.member_allocations is not distinct from new.member_allocations
      and old.savings_allocations is not distinct from new.savings_allocations then return new; end if;
  end if;
  if tg_table_name not in ('transactions', 'balance_transfers', 'balance_adjustments') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  record_id := case when tg_op = 'DELETE' then old.id else new.id end;
  if tg_table_name = 'transactions' then
    record_entity_type := 'transaction'; record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Transaksi ' || (case when tg_op = 'DELETE' then old.category else new.category end)
      || case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
  elsif tg_table_name = 'balance_transfers' then
    record_entity_type := 'transfer'; record_action := 'transfer'; record_summary := 'Transfer saldo dicatat';
  else
    record_entity_type := 'adjustment'; record_action := 'adjustment'; record_summary := 'Penyesuaian saldo dicatat';
  end if;
  record_details := jsonb_build_object(
    'before', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    'after', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );
  insert into public.audit_logs (household_id, user_id, action, entity_type, entity_id, summary, details)
  values (record_household_id, record_user_id, record_action, record_entity_type, record_id, left(record_summary, 180), record_details);
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

alter table public.savings_accounts enable row level security;
drop policy if exists "Members can read savings accounts" on public.savings_accounts;
create policy "Members can read savings accounts" on public.savings_accounts
for select to authenticated using (public.is_household_member(household_id));

revoke all on public.savings_accounts from public, anon, authenticated;
grant select on public.savings_accounts to authenticated;
revoke execute on function public.seed_default_savings_accounts() from public, anon, authenticated;
revoke execute on function public.touch_savings_account_updated_at() from public, anon, authenticated;
revoke execute on function public.calculate_savings_account_balance(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.save_savings_account(uuid, text, boolean) from public, anon;
revoke execute on function public.archive_savings_account(uuid, text) from public, anon;
revoke execute on function public.update_household_name(text) from public, anon;
revoke execute on function public.update_household_payday(boolean, smallint) from public, anon;
grant execute on function public.save_savings_account(uuid, text, boolean) to authenticated;
grant execute on function public.archive_savings_account(uuid, text) to authenticated;
grant execute on function public.update_household_name(text) to authenticated;
grant execute on function public.update_household_payday(boolean, smallint) to authenticated;

commit;
notify pgrst, 'reload schema';
