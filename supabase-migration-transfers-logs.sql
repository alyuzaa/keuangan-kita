-- ============================================================
-- KEUANGAN KITA — Transfer, penyesuaian, anti-minus, dan Logs
-- Jalankan satu kali untuk project yang sudah memakai schema lama.
-- Aman dijalankan ulang karena object dibuat secara idempotent.
-- ============================================================

create table if not exists public.balance_transfers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  from_balance text not null check (from_balance in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  to_balance text not null check (to_balance in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  amount bigint not null check (amount > 0),
  date date not null,
  notes text not null default '' check (char_length(notes) <= 120),
  created_at timestamptz not null default now(),
  constraint balance_transfer_different_destination check (from_balance <> to_balance)
);

create table if not exists public.balance_adjustments (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  balance_key text not null check (balance_key in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  previous_balance bigint not null,
  new_balance bigint not null check (new_balance >= 0),
  delta bigint not null,
  notes text not null check (char_length(btrim(notes)) between 3 and 120),
  created_at timestamptz not null default now(),
  constraint balance_adjustment_delta_matches check (delta = new_balance - previous_balance),
  constraint balance_adjustment_changes_value check (new_balance <> previous_balance)
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('create', 'update', 'delete', 'transfer', 'adjustment')),
  entity_type text not null check (entity_type in ('transaction', 'asset', 'transfer', 'adjustment')),
  entity_id uuid,
  summary text not null check (char_length(summary) between 1 and 180),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists balance_transfers_household_date_idx
  on public.balance_transfers(household_id, date desc, created_at desc);
create index if not exists balance_adjustments_household_created_idx
  on public.balance_adjustments(household_id, created_at desc);
create index if not exists audit_logs_household_created_idx
  on public.audit_logs(household_id, created_at desc);

-- Menghitung satu pos saldo dari transaksi, transfer, dan penyesuaian.
-- excluded_transaction_id dipakai trigger update/delete agar baris lama tidak
-- dihitung dua kali ketika menguji saldo hasil perubahan.
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
begin
  if target_balance_key not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;

  select coalesce(sum(
    case
      when tx.type = 'income' and target_balance_key = 'husband' then tx.husband_allocation
      when tx.type = 'income' and target_balance_key = 'wife' then tx.wife_allocation
      when tx.type = 'income' and target_balance_key = 'savings' then tx.savings_allocation
      when tx.type = 'income' and target_balance_key = 'wife_savings' then tx.wife_savings_allocation
      when tx.type = 'income' and target_balance_key = 'education' then tx.education_allocation
      when tx.type = 'outcome' and tx.source = target_balance_key then -tx.amount
      else 0
    end
  ), 0)::bigint
  into result_balance
  from public.transactions as tx
  where tx.household_id = target_household_id
    and (excluded_transaction_id is null or tx.id <> excluded_transaction_id);

  select result_balance
    + coalesce(sum(case when bt.to_balance = target_balance_key then bt.amount else 0 end), 0)::bigint
    - coalesce(sum(case when bt.from_balance = target_balance_key then bt.amount else 0 end), 0)::bigint
  into result_balance
  from public.balance_transfers as bt
  where bt.household_id = target_household_id;

  select result_balance + coalesce(sum(ba.delta), 0)::bigint
  into result_balance
  from public.balance_adjustments as ba
  where ba.household_id = target_household_id
    and ba.balance_key = target_balance_key;

  return result_balance;
end;
$$;

-- Menolak insert/update/delete transaksi jika hasil akhirnya membuat salah satu
-- pos saldo menjadi negatif. Lock per-household mencegah dua request bersamaan
-- sama-sama memakai saldo yang sama.
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

  perform 1
  from public.households
  where id = affected_household_id
  for update;

  excluded_id := case when tg_op in ('UPDATE', 'DELETE') then old.id else null end;

  foreach balance_key in array array['husband', 'wife', 'savings', 'wife_savings', 'education'] loop
    projected_balance := public.calculate_household_balance(
      affected_household_id,
      balance_key,
      excluded_id
    );

    if tg_op in ('INSERT', 'UPDATE') then
      if new.type = 'income' then
        projected_balance := projected_balance + case balance_key
          when 'husband' then new.husband_allocation
          when 'wife' then new.wife_allocation
          when 'savings' then new.savings_allocation
          when 'wife_savings' then new.wife_savings_allocation
          when 'education' then new.education_allocation
          else 0
        end;
      elsif new.type = 'outcome' and new.source = balance_key then
        projected_balance := projected_balance - new.amount;
      end if;
    end if;

    if projected_balance < 0 then
      raise exception 'Saldo % tidak mencukupi. Transaksi membuat saldo menjadi minus.', balance_key;
    end if;
  end loop;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_negative_household_balance_trigger on public.transactions;
create trigger prevent_negative_household_balance_trigger
before insert or update or delete on public.transactions
for each row execute function public.prevent_negative_household_balance();

-- Transfer hanya tersedia lewat RPC sehingga validasi saldo dan pencatatan
-- transfer selalu dilakukan secara atomik di database.
create or replace function public.create_balance_transfer(
  p_from_balance text,
  p_to_balance text,
  p_amount bigint,
  p_date date,
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
  current_balance bigint;
  new_transfer_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_from_balance not in ('husband', 'wife', 'savings', 'wife_savings', 'education')
     or p_to_balance not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if p_from_balance = p_to_balance then
    raise exception 'Sumber dan tujuan transfer harus berbeda';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Nominal transfer harus lebih dari nol';
  end if;
  if p_date is null then
    raise exception 'Tanggal transfer wajib diisi';
  end if;
  if char_length(coalesce(p_notes, '')) > 120 then
    raise exception 'Catatan maksimal 120 karakter';
  end if;

  select member.household_id
  into member_household_id
  from public.household_members as member
  where member.user_id = current_user_id;

  if member_household_id is null then
    raise exception 'Household member not found';
  end if;

  perform 1
  from public.households
  where id = member_household_id
  for update;

  current_balance := public.calculate_household_balance(member_household_id, p_from_balance);
  if current_balance < p_amount then
    raise exception 'Saldo sumber tidak mencukupi';
  end if;

  insert into public.balance_transfers (
    household_id, user_id, from_balance, to_balance, amount, date, notes
  ) values (
    member_household_id, current_user_id, p_from_balance, p_to_balance,
    p_amount, p_date, btrim(coalesce(p_notes, ''))
  )
  returning id into new_transfer_id;

  return new_transfer_id;
end;
$$;

-- Penyesuaian menyimpan saldo sebelum/sesudah dan delta. Riwayat transaksi
-- tidak diubah, sehingga koreksi tetap dapat diaudit melalui tab Logs.
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
  old_balance bigint;
  new_adjustment_id uuid;
  clean_notes text := btrim(coalesce(p_notes, ''));
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_balance_key not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if p_new_balance is null or p_new_balance < 0 then
    raise exception 'Saldo baru tidak boleh minus';
  end if;
  if char_length(clean_notes) not between 3 and 120 then
    raise exception 'Alasan penyesuaian harus 3 sampai 120 karakter';
  end if;

  select member.household_id
  into member_household_id
  from public.household_members as member
  where member.user_id = current_user_id;

  if member_household_id is null then
    raise exception 'Household member not found';
  end if;

  perform 1
  from public.households
  where id = member_household_id
  for update;

  old_balance := public.calculate_household_balance(member_household_id, p_balance_key);
  if old_balance = p_new_balance then
    raise exception 'Saldo baru sama dengan saldo saat ini';
  end if;

  insert into public.balance_adjustments (
    household_id, user_id, balance_key, previous_balance, new_balance, delta, notes
  ) values (
    member_household_id, current_user_id, p_balance_key, old_balance,
    p_new_balance, p_new_balance - old_balance, clean_notes
  )
  returning id into new_adjustment_id;

  return new_adjustment_id;
end;
$$;

-- Satu trigger audit untuk transaksi, aset, transfer, dan penyesuaian.
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
  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  record_id := case when tg_op = 'DELETE' then old.id else new.id end;

  if tg_table_name = 'transactions' then
    record_entity_type := 'transaction';
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Transaksi ' || (case when tg_op = 'DELETE' then old.category else new.category end) ||
      case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
  elsif tg_table_name = 'assets' then
    record_entity_type := 'asset';
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    record_summary := 'Aset ' || (case when tg_op = 'DELETE' then old.name else new.name end) ||
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

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists audit_transactions_trigger on public.transactions;
create trigger audit_transactions_trigger
after insert or update or delete on public.transactions
for each row execute function public.write_finance_audit_log();

drop trigger if exists audit_assets_trigger on public.assets;
create trigger audit_assets_trigger
after insert or update or delete on public.assets
for each row execute function public.write_finance_audit_log();

drop trigger if exists audit_balance_transfers_trigger on public.balance_transfers;
create trigger audit_balance_transfers_trigger
after insert on public.balance_transfers
for each row execute function public.write_finance_audit_log();

drop trigger if exists audit_balance_adjustments_trigger on public.balance_adjustments;
create trigger audit_balance_adjustments_trigger
after insert on public.balance_adjustments
for each row execute function public.write_finance_audit_log();

alter table public.balance_transfers enable row level security;
alter table public.balance_adjustments enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists "Members can read balance transfers" on public.balance_transfers;
create policy "Members can read balance transfers"
on public.balance_transfers
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read balance adjustments" on public.balance_adjustments;
create policy "Members can read balance adjustments"
on public.balance_adjustments
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read audit logs" on public.audit_logs;
create policy "Members can read audit logs"
on public.audit_logs
for select
to authenticated
using ((select public.is_household_member(household_id)));

revoke all on public.balance_transfers from public, anon, authenticated;
revoke all on public.balance_adjustments from public, anon, authenticated;
revoke all on public.audit_logs from public, anon, authenticated;

grant select on public.balance_transfers to authenticated;
grant select on public.balance_adjustments to authenticated;
grant select on public.audit_logs to authenticated;

revoke execute on function public.calculate_household_balance(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.prevent_negative_household_balance() from public, anon, authenticated;
revoke execute on function public.write_finance_audit_log() from public, anon, authenticated;
revoke execute on function public.create_balance_transfer(text, text, bigint, date, text) from public, anon;
revoke execute on function public.adjust_household_balance(text, bigint, text) from public, anon;

grant execute on function public.create_balance_transfer(text, text, bigint, date, text) to authenticated;
grant execute on function public.adjust_household_balance(text, bigint, text) to authenticated;
