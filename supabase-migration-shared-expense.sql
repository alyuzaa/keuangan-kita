-- Pengeluaran Bersama
-- Memungkinkan anggota aktif memakai saldo anggota aktif lain hanya ketika
-- kategori outcome adalah "Pengeluaran Bersama". Pencatat tetap tersimpan
-- pada transactions.user_id, sedangkan saldo yang berkurang mengikuti
-- transactions.source_member_id.

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
    if new.source_member_id <> auth.uid()
      and not public.is_household_master(new.household_id)
      and lower(trim(coalesce(new.category, ''))) <> lower('Pengeluaran Bersama') then
      raise exception 'Hanya room master yang dapat memakai saldo anggota lain, kecuali untuk Pengeluaran Bersama';
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
