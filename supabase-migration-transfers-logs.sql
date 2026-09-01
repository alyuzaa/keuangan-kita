-- ============================================================
-- MIGRASI v12 — Transfer, penyesuaian, anti-minus, dan audit log
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- Data lama tidak dihapus atau diubah.
-- ============================================================

create table if not exists public.balance_transfers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  from_balance text not null check (from_balance in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  to_balance text not null check (to_balance in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  amount bigint not null check (amount > 0),
  date date not null default current_date,
  notes text not null default '' check (char_length(notes) <= 120),
  created_at timestamptz not null default now(),
  constraint balance_transfer_destinations_differ check (from_balance <> to_balance)
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
  entity_id uuid not null,
  summary text not null check (char_length(summary) between 1 and 160),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists balance_transfers_household_date_idx
  on public.balance_transfers(household_id, date desc, created_at desc);
create index if not exists balance_adjustments_household_created_idx
  on public.balance_adjustments(household_id, created_at desc);
create index if not exists audit_logs_household_created_idx
  on public.audit_logs(household_id, created_at desc);

-- Menghitung satu pos saldo dari seluruh sumber data.
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
  calculated_balance bigint := 0;
begin
  if target_balance_key not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Invalid balance key';
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
  into calculated_balance
  from public.transactions as tx
  where tx.household_id = target_household_id
    and (excluded_transaction_id is null or tx.id <> excluded_transaction_id);

  calculated_balance := calculated_balance + coalesce((
    select sum(
      case
        when transfer.to_balance = target_balance_key then transfer.amount
        when transfer.from_balance = target_balance_key then -transfer.amount
        else 0
      end
    )::bigint
    from public.balance_transfers as transfer
    where transfer.household_id = target_household_id
  ), 0);

  calculated_balance := calculated_balance + coalesce((
    select sum(adjustment.delta)::bigint
    from public.balance_adjustments as adjustment
    where adjustment.household_id = target_household_id
      and adjustment.balance_key = target_balance_key
  ), 0);

  return calculated_balance;
end;
$$;

-- Semua perubahan transaksi divalidasi terhadap saldo akhir. Penguncian
-- household menyerialkan permintaan dari dua perangkat yang datang bersamaan.
create or replace function public.prevent_negative_household_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_household_id uuid;
  balance_key text;
  projected_balance bigint;
  balance_label text;
begin
  target_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;

  if tg_op = 'UPDATE' and new.household_id <> old.household_id then
    raise exception 'Transaction household cannot be changed';
  end if;

  perform 1 from public.households where id = target_household_id for update;

  foreach balance_key in array array['husband', 'wife', 'savings', 'wife_savings', 'education'] loop
    projected_balance := public.calculate_household_balance(
      target_household_id,
      balance_key,
      case when tg_op in ('UPDATE', 'DELETE') then old.id else null end
    );

    if tg_op <> 'DELETE' then
      if new.type = 'income' then
        projected_balance := projected_balance + case balance_key
          when 'husband' then new.husband_allocation
          when 'wife' then new.wife_allocation
          when 'savings' then new.savings_allocation
          when 'wife_savings' then new.wife_savings_allocation
          when 'education' then new.education_allocation
          else 0
        end;
      elsif new.source = balance_key then
        projected_balance := projected_balance - new.amount;
      end if;
    end if;

    if projected_balance < 0 then
      balance_label := case balance_key
        when 'husband' then 'Uang suami'
        when 'wife' then 'Uang istri'
        when 'savings' then 'Tabungan bersama'
        when 'wife_savings' then 'Tabungan istri'
        else 'Pendidikan'
      end;
      raise exception 'Saldo % tidak mencukupi', balance_label;
    end if;
  end loop;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists prevent_negative_household_balance_trigger on public.transactions;
create trigger prevent_negative_household_balance_trigger
before insert or update or delete on public.transactions
for each row execute function public.prevent_negative_household_balance();

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
  target_household_id uuid;
  available_balance bigint;
  new_transfer_id uuid;
begin
  if current_user_id is null then raise exception 'Authentication required'; end if;
  if p_from_balance not in ('husband', 'wife', 'savings', 'wife_savings', 'education')
    or p_to_balance not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if p_from_balance = p_to_balance then raise exception 'Pos asal dan tujuan harus berbeda'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nominal transfer harus lebih dari nol'; end if;
  if p_date is null then raise exception 'Tanggal transfer wajib diisi'; end if;
  if char_length(coalesce(p_notes, '')) > 120 then raise exception 'Catatan terlalu panjang'; end if;

  select member.household_id into target_household_id
  from public.household_members as member
  where member.user_id = current_user_id;
  if target_household_id is null then raise exception 'Household member not found'; end if;

  perform 1 from public.households where id = target_household_id for update;
  available_balance := public.calculate_household_balance(target_household_id, p_from_balance);
  if available_balance < p_amount then raise exception 'Saldo sumber tidak mencukupi'; end if;

  insert into public.balance_transfers (
    household_id, user_id, from_balance, to_balance, amount, date, notes
  ) values (
    target_household_id, current_user_id, p_from_balance, p_to_balance, p_amount, p_date, btrim(coalesce(p_notes, ''))
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
  target_household_id uuid;
  current_balance bigint;
  new_adjustment_id uuid;
begin
  if current_user_id is null then raise exception 'Authentication required'; end if;
  if p_balance_key not in ('husband', 'wife', 'savings', 'wife_savings', 'education') then
    raise exception 'Pos saldo tidak valid';
  end if;
  if p_new_balance is null or p_new_balance < 0 then raise exception 'Saldo baru tidak boleh minus'; end if;
  if char_length(btrim(coalesce(p_notes, ''))) not between 3 and 120 then
    raise exception 'Alasan penyesuaian harus berisi 3 sampai 120 karakter';
  end if;

  select member.household_id into target_household_id
  from public.household_members as member
  where member.user_id = current_user_id;
  if target_household_id is null then raise exception 'Household member not found'; end if;

  perform 1 from public.households where id = target_household_id for update;
  current_balance := public.calculate_household_balance(target_household_id, p_balance_key);
  if current_balance = p_new_balance then raise exception 'Saldo baru masih sama dengan saldo saat ini'; end if;

  insert into public.balance_adjustments (
    household_id, user_id, balance_key, previous_balance, new_balance, delta, notes
  ) values (
    target_household_id, current_user_id, p_balance_key, current_balance, p_new_balance,
    p_new_balance - current_balance, btrim(p_notes)
  ) returning id into new_adjustment_id;

  return new_adjustment_id;
end;
$$;

-- Audit log dibuat di database sehingga perubahan dari perangkat mana pun
-- tetap tercatat dan tidak bergantung pada JavaScript klien.
create or replace function public.write_finance_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_household_id uuid;
  actor_user_id uuid;
  target_entity_id uuid;
  log_action text;
  log_entity_type text;
  log_summary text;
  log_details jsonb;
begin
  target_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  actor_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.user_id else new.user_id end);
  target_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
  log_details := jsonb_build_object(
    'before', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    'after', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if tg_table_name = 'transactions' then
    log_action := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' else 'delete' end;
    log_entity_type := 'transaction';
    log_summary := case tg_op
      when 'INSERT' then 'Menambahkan ' || new.type
      when 'UPDATE' then 'Mengubah ' || new.type
      else 'Menghapus ' || old.type
    end;
  elsif tg_table_name = 'assets' then
    log_action := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' else 'delete' end;
    log_entity_type := 'asset';
    log_summary := case tg_op
      when 'INSERT' then 'Menambahkan aset'
      when 'UPDATE' then 'Mengubah aset'
      else 'Menghapus aset'
    end;
  elsif tg_table_name = 'balance_transfers' then
    log_action := 'transfer';
    log_entity_type := 'transfer';
    log_summary := 'Mentransfer saldo';
  else
    log_action := 'adjustment';
    log_entity_type := 'adjustment';
    log_summary := 'Menyesuaikan saldo';
  end if;

  insert into public.audit_logs (
    household_id, user_id, action, entity_type, entity_id, summary, details
  ) values (
    target_household_id, actor_user_id, log_action, log_entity_type, target_entity_id, log_summary, log_details
  );

  if tg_op = 'DELETE' then return old; end if;
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
on public.balance_transfers for select to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read balance adjustments" on public.balance_adjustments;
create policy "Members can read balance adjustments"
on public.balance_adjustments for select to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read audit logs" on public.audit_logs;
create policy "Members can read audit logs"
on public.audit_logs for select to authenticated
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
