-- ============================================================
-- KEUANGAN KITA — Logs hanya untuk perubahan saldo penting
-- Jalankan setelah supabase-migration-family-members.sql.
-- Aman dijalankan ulang.
-- ============================================================

begin;

-- Aset dan tagihan tidak memindahkan saldo kas. Riwayat lamanya tetap aman
-- di database, tetapi perubahan baru tidak lagi menambah audit log.
drop trigger if exists audit_assets_trigger on public.assets;
drop trigger if exists audit_monthly_bills_trigger on public.monthly_bills;
drop trigger if exists audit_monthly_bill_payments_trigger on public.monthly_bill_payments;

-- Transaksi hanya dicatat saat bagian yang memengaruhi saldo atau laporan
-- bulanan berubah. Edit kategori/keterangan saja tidak memenuhi syarat ini.
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
      and old.husband_allocation is not distinct from new.husband_allocation
      and old.wife_allocation is not distinct from new.wife_allocation
      and old.savings_allocation is not distinct from new.savings_allocation
      and old.wife_savings_allocation is not distinct from new.wife_savings_allocation
      and old.education_allocation is not distinct from new.education_allocation
      and old.member_allocations is not distinct from new.member_allocations
    then
      return new;
    end if;
  end if;

  if tg_table_name not in ('transactions', 'balance_transfers', 'balance_adjustments') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  record_id := case when tg_op = 'DELETE' then old.id else new.id end;

  if tg_table_name = 'transactions' then
    record_entity_type := 'transaction';
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Transaksi ' || (case when tg_op = 'DELETE' then old.category else new.category end) ||
      case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
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

commit;
notify pgrst, 'reload schema';
