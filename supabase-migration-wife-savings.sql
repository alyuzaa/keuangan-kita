-- ============================================================
-- KEUANGAN KITA — Tambah saldo Tabungan Istri
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- Aman untuk seluruh transaksi yang sudah ada.
-- ============================================================

begin;

alter table public.transactions
  add column if not exists wife_savings_allocation bigint not null default 0;

alter table public.transactions
  drop constraint if exists transactions_wife_savings_allocation_check;

alter table public.transactions
  add constraint transactions_wife_savings_allocation_check
  check (wife_savings_allocation >= 0);

alter table public.transactions
  drop constraint if exists transactions_source_check;

alter table public.transactions
  add constraint transactions_source_check
  check (source is null or source in ('husband', 'wife', 'savings', 'wife_savings', 'education'));

alter table public.transactions
  drop constraint if exists transaction_allocation_is_valid;

alter table public.transactions
  add constraint transaction_allocation_is_valid check (
    (
      type = 'income'
      and source is null
      and husband_allocation
        + wife_allocation
        + savings_allocation
        + wife_savings_allocation
        + education_allocation = amount
    )
    or
    (
      type = 'outcome'
      and source is not null
      and husband_allocation = 0
      and wife_allocation = 0
      and savings_allocation = 0
      and wife_savings_allocation = 0
      and education_allocation = 0
    )
  );

commit;
