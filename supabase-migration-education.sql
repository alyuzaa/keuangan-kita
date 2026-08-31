-- ============================================================
-- KEUANGAN KITA — Tambah saldo Uang Pendidikan
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- Aman untuk data transaksi yang sudah ada.
-- ============================================================

begin;

alter table public.transactions
  add column if not exists education_allocation bigint not null default 0;

alter table public.transactions
  drop constraint if exists transactions_education_allocation_check;

alter table public.transactions
  add constraint transactions_education_allocation_check
  check (education_allocation >= 0);

alter table public.transactions
  drop constraint if exists transactions_source_check;

alter table public.transactions
  add constraint transactions_source_check
  check (source is null or source in ('husband', 'wife', 'savings', 'education'));

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
        + education_allocation = amount
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
  );

commit;
