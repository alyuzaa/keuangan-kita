-- ============================================================
-- KEUANGAN KITA v24 — Default ruang baru dan Logs perubahan aset
-- Jalankan setelah supabase-migration-dynamic-savings-settings.sql.
-- Aman dijalankan ulang. Tidak menghapus tabungan atau data ruang lama.
-- ============================================================

begin;

-- Hanya berlaku sebagai default bagi room yang dibuat setelah migration ini.
alter table public.households
  add column if not exists payday_enabled boolean not null default false,
  add column if not exists payday_day smallint;

alter table public.households
  alter column payday_enabled set default false,
  alter column payday_day drop not null,
  alter column payday_day set default null;

alter table public.households drop constraint if exists households_payday_day_check;
alter table public.households
  add constraint households_payday_day_check
  check (payday_day is null or payday_day between 1 and 31);

-- Room baru hanya memperoleh satu pos tabungan. Nilai aset dihitung langsung
-- dari tabel assets dan tetap tampil sebagai baris tersendiri di Beranda.
create or replace function public.seed_default_savings_accounts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.savings_accounts (
    household_id, name, include_in_net_worth, legacy_key, sort_order, created_by
  ) values (
    new.id, 'Tabungan pribadi', true, 'savings', 0, new.created_by
  )
  on conflict (household_id, legacy_key) do nothing;
  return new;
end;
$$;

drop trigger if exists seed_default_savings_accounts_trigger on public.households;
create trigger seed_default_savings_accounts_trigger
after insert on public.households
for each row execute function public.seed_default_savings_accounts();

create or replace function public.update_household_payday(enabled boolean, salary_day smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare member_household_id uuid;
begin
  select household_id into member_household_id
  from public.household_members
  where user_id = auth.uid();

  if member_household_id is null or not public.is_household_master(member_household_id) then
    raise exception 'Hanya room master yang dapat mengatur tanggal gajian';
  end if;
  if coalesce(enabled, false) and coalesce(salary_day, 0) not between 1 and 31 then
    raise exception 'Tanggal gajian harus antara 1 dan 31';
  end if;

  update public.households
  set payday_enabled = coalesce(enabled, false),
      payday_day = case when coalesce(enabled, false) then salary_day else null end
  where id = member_household_id;
end;
$$;

-- Aset dicatat saat ditambah/dihapus, atau ketika jumlah/nilai berubah.
-- Perubahan nama dan catatan saja tidak memenuhi Logs keuangan penting.
create or replace function public.write_finance_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  record_household_id uuid;
  record_user_id uuid;
  record_id uuid;
  record_action text;
  record_entity_type text;
  record_summary text;
  record_details jsonb;
begin
  if tg_table_name = 'transactions' and tg_op = 'UPDATE' then
    if old.type is not distinct from new.type
      and old.amount is not distinct from new.amount
      and old.date is not distinct from new.date
      and old.source is not distinct from new.source
      and old.source_member_id is not distinct from new.source_member_id
      and old.source_savings_id is not distinct from new.source_savings_id
      and old.husband_allocation is not distinct from new.husband_allocation
      and old.wife_allocation is not distinct from new.wife_allocation
      and old.savings_allocation is not distinct from new.savings_allocation
      and old.wife_savings_allocation is not distinct from new.wife_savings_allocation
      and old.education_allocation is not distinct from new.education_allocation
      and old.member_allocations is not distinct from new.member_allocations
      and old.savings_allocations is not distinct from new.savings_allocations
    then
      return new;
    end if;
  end if;

  if tg_table_name = 'assets' and tg_op = 'UPDATE' then
    if old.quantity is not distinct from new.quantity
      and old.purchase_value is not distinct from new.purchase_value
      and old.current_value is not distinct from new.current_value
    then
      return new;
    end if;
  end if;

  if tg_table_name not in ('transactions', 'assets', 'balance_transfers', 'balance_adjustments') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  record_id := case when tg_op = 'DELETE' then old.id else new.id end;

  if tg_table_name = 'transactions' then
    record_entity_type := 'transaction';
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Transaksi ' || (case when tg_op = 'DELETE' then old.category else new.category end)
      || case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
  elsif tg_table_name = 'assets' then
    record_entity_type := 'asset';
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Aset ' || (case when tg_op = 'DELETE' then old.name else new.name end)
      || case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
  elsif tg_table_name = 'balance_transfers' then
    record_entity_type := 'transfer';
    record_action := 'transfer';
    record_summary := 'Transfer saldo dicatat';
  else
    record_entity_type := 'adjustment';
    record_action := 'adjustment';
    record_summary := 'Penyesuaian saldo dicatat';
  end if;

  record_details := jsonb_build_object(
    'before', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    'after', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  insert into public.audit_logs (
    household_id, user_id, action, entity_type, entity_id, summary, details
  ) values (
    record_household_id, record_user_id, record_action, record_entity_type,
    record_id, left(record_summary, 180), record_details
  );

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists audit_assets_trigger on public.assets;
create trigger audit_assets_trigger
after insert or update or delete on public.assets
for each row execute function public.write_finance_audit_log();

revoke execute on function public.seed_default_savings_accounts() from public, anon, authenticated;
revoke execute on function public.write_finance_audit_log() from public, anon, authenticated;
revoke execute on function public.update_household_payday(boolean, smallint) from public, anon;
grant execute on function public.update_household_payday(boolean, smallint) to authenticated;

commit;
notify pgrst, 'reload schema';
