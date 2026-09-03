-- ============================================================
-- KEUANGAN KITA — Supabase schema, functions, grants, dan RLS
-- Jalankan satu kali di Supabase Dashboard → SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 50),
  invite_code text not null unique check (char_length(invite_code) = 12),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  email text not null check (char_length(email) between 3 and 320),
  display_name text not null check (char_length(display_name) between 1 and 40),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id)
);

-- Menjaga schema tetap dapat diperbarui jika tabel dibuat oleh versi lama.
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

alter table public.household_members
  add column if not exists display_name text;

update public.household_members
set display_name = left(split_part(email, '@', 1), 40)
where display_name is null or btrim(display_name) = '';

alter table public.household_members
  drop constraint if exists household_members_display_name_check;

alter table public.household_members
  add constraint household_members_display_name_check
  check (char_length(btrim(display_name)) between 1 and 40);

alter table public.household_members
  alter column display_name set not null;

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  type text not null check (type in ('income', 'outcome')),
  amount bigint not null check (amount > 0),
  date date not null,
  category text not null check (char_length(category) between 1 and 50),
  source text check (source is null or source in ('husband', 'wife', 'savings', 'wife_savings', 'education')),
  description text not null default '' check (char_length(description) <= 100),
  husband_allocation bigint not null default 0 check (husband_allocation >= 0),
  wife_allocation bigint not null default 0 check (wife_allocation >= 0),
  savings_allocation bigint not null default 0 check (savings_allocation >= 0),
  wife_savings_allocation bigint not null default 0 check (wife_savings_allocation >= 0),
  education_allocation bigint not null default 0 check (education_allocation >= 0),
  created_at timestamptz not null default now(),
  constraint transaction_allocation_is_valid check (
    (
      type = 'income'
      and source is null
      and husband_allocation + wife_allocation + savings_allocation + wife_savings_allocation + education_allocation = amount
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
  )
);

create table if not exists public.assets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  asset_type text not null check (char_length(asset_type) between 1 and 40),
  name text not null check (char_length(name) between 1 and 80),
  quantity numeric(18, 2) not null default 1 check (quantity > 0),
  unit text not null default 'unit' check (char_length(unit) between 1 and 20),
  purchase_value bigint not null default 0 check (purchase_value >= 0),
  current_value bigint not null check (current_value >= 0),
  notes text not null default '' check (char_length(notes) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists household_members_user_id_idx
  on public.household_members(user_id);
create index if not exists transactions_household_date_idx
  on public.transactions(household_id, date desc);
create index if not exists assets_household_idx
  on public.assets(household_id);

-- Email disalin dari akun Auth agar hanya pasangan dalam household yang dapat
-- melihat identitas pencatat melalui policy household_members.
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

  if new.display_name is null or btrim(new.display_name) = '' then
    new.display_name := left(split_part(new.email, '@', 1), 40);
  end if;

  return new;
end;
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

drop trigger if exists set_household_member_email_trigger on public.household_members;
create trigger set_household_member_email_trigger
before insert or update of user_id on public.household_members
for each row execute function public.set_household_member_email();

-- Helper ini mencegah policy household_members menjadi rekursif.
create or replace function public.is_household_member(target_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members as member
    where member.household_id = target_household_id
      and member.user_id = (select auth.uid())
  );
$$;

-- Pengguna pertama membuat household dan otomatis menjadi owner.
create or replace function public.create_household(household_name text)
returns table(created_household_id uuid, created_invite_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  new_household_id uuid := gen_random_uuid();
  new_invite_code text;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  if exists (
    select 1 from public.household_members where user_id = current_user_id
  ) then
    raise exception 'User already belongs to a household';
  end if;

  loop
    new_invite_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (
      select 1 from public.households where invite_code = new_invite_code
    );
  end loop;

  insert into public.households (id, name, invite_code, created_by)
  values (new_household_id, trim(household_name), new_invite_code, current_user_id);

  insert into public.household_members (household_id, user_id, role)
  values (new_household_id, current_user_id, 'owner');

  return query select new_household_id, new_invite_code;
end;
$$;

-- Pasangan bergabung hanya jika mengetahui kode undangan.
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

  if exists (
    select 1 from public.household_members where user_id = current_user_id
  ) then
    raise exception 'User already belongs to a household';
  end if;

  select id
  into target_household_id
  from public.households
  where invite_code = upper(trim(invitation_code));

  if target_household_id is null then
    raise exception 'Invitation code not found';
  end if;

  -- Mengunci household selama pengecekan agar dua permintaan bersamaan
  -- tidak dapat membuat anggota ketiga.
  perform 1
  from public.households
  where id = target_household_id
  for update;

  if (
    select count(*)
    from public.household_members
    where household_id = target_household_id
  ) >= 2 then
    raise exception 'Household already has two members';
  end if;

  insert into public.household_members (household_id, user_id, role)
  values (target_household_id, current_user_id, 'member');

  return target_household_id;
end;
$$;

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.transactions enable row level security;
alter table public.assets enable row level security;

drop policy if exists "Members can read their household" on public.households;
create policy "Members can read their household"
on public.households
for select
to authenticated
using ((select public.is_household_member(id)));

drop policy if exists "Members can read household membership" on public.household_members;
create policy "Members can read household membership"
on public.household_members
for select
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_household_member(household_id))
);

drop policy if exists "Members can read transactions" on public.transactions;
create policy "Members can read transactions"
on public.transactions
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can add transactions" on public.transactions;
create policy "Members can add transactions"
on public.transactions
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and (select public.is_household_member(household_id))
);

drop policy if exists "Members can update transactions" on public.transactions;
create policy "Members can update transactions"
on public.transactions
for update
to authenticated
using ((select public.is_household_member(household_id)))
with check ((select public.is_household_member(household_id)));

drop policy if exists "Members can delete transactions" on public.transactions;
create policy "Members can delete transactions"
on public.transactions
for delete
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can read assets" on public.assets;
create policy "Members can read assets"
on public.assets
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Members can add assets" on public.assets;
create policy "Members can add assets"
on public.assets
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and (select public.is_household_member(household_id))
);

drop policy if exists "Members can update assets" on public.assets;
create policy "Members can update assets"
on public.assets
for update
to authenticated
using ((select public.is_household_member(household_id)))
with check ((select public.is_household_member(household_id)));

drop policy if exists "Members can delete assets" on public.assets;
create policy "Members can delete assets"
on public.assets
for delete
to authenticated
using ((select public.is_household_member(household_id)));

-- Least-privilege grants untuk Data API.
revoke all on public.households from public, anon, authenticated;
revoke all on public.household_members from public, anon, authenticated;
revoke all on public.transactions from public, anon, authenticated;
revoke all on public.assets from public, anon, authenticated;

grant select on public.households to authenticated;
grant select on public.household_members to authenticated;
grant select, insert, update, delete on public.transactions to authenticated;
grant select, insert, update, delete on public.assets to authenticated;

revoke execute on function public.is_household_member(uuid) from public, anon;
revoke execute on function public.set_household_member_email() from public, anon, authenticated;
revoke execute on function public.update_own_display_name(text) from public, anon;
revoke execute on function public.create_household(text) from public, anon;
revoke execute on function public.join_household(text) from public, anon;

grant execute on function public.is_household_member(uuid) to authenticated;
grant execute on function public.update_own_display_name(text) to authenticated;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.join_household(text) to authenticated;

-- Fitur transfer, penyesuaian saldo, pencegahan saldo minus, dan audit log.
-- Bagian berikut juga tersedia sebagai migration terpisah untuk instalasi lama.
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

-- Fitur tagihan bulanan dan status pembayaran per bulan.
-- Bagian berikut juga tersedia sebagai migration terpisah untuk instalasi lama.
-- ============================================================
-- KEUANGAN KITA — Tagihan bulanan dan status pembayaran
-- Jalankan setelah supabase-migration-transfers-logs.sql.
-- ============================================================

begin;

create table if not exists public.monthly_bills (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  balance_key text not null check (balance_key in ('husband', 'wife')),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  amount bigint not null check (amount > 0),
  subscription_day smallint not null check (subscription_day between 1 and 31),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, household_id)
);

create table if not exists public.monthly_bill_payments (
  id uuid primary key default gen_random_uuid(),
  monthly_bill_id uuid not null,
  household_id uuid not null,
  billing_month date not null,
  marked_by uuid not null references auth.users(id) on delete cascade,
  paid_at timestamptz not null default now(),
  constraint monthly_bill_payment_bill_household_fk
    foreign key (monthly_bill_id, household_id)
    references public.monthly_bills(id, household_id)
    on delete cascade,
  constraint monthly_bill_payment_month_start_check
    check (billing_month = date_trunc('month', billing_month)::date),
  unique (monthly_bill_id, billing_month)
);

create index if not exists monthly_bills_household_balance_idx
  on public.monthly_bills(household_id, balance_key, subscription_day, created_at);
create index if not exists monthly_bill_payments_household_month_idx
  on public.monthly_bill_payments(household_id, billing_month, monthly_bill_id);

create or replace function public.set_monthly_bill_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_monthly_bill_updated_at_trigger on public.monthly_bills;
create trigger set_monthly_bill_updated_at_trigger
before update on public.monthly_bills
for each row execute function public.set_monthly_bill_updated_at();

-- Owner/anggota dipetakan ke Uang suami/Uang istri. Helper security definer
-- membuat pemeriksaan ini tetap aman dan tidak memicu policy rekursif.
create or replace function public.can_manage_household_balance(
  target_household_id uuid,
  target_balance_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members as member
    where member.household_id = target_household_id
      and member.user_id = (select auth.uid())
      and (
        (member.role = 'owner' and target_balance_key = 'husband')
        or (member.role = 'member' and target_balance_key = 'wife')
      )
  );
$$;

create or replace function public.can_manage_monthly_bill(
  target_bill_id uuid,
  target_household_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.monthly_bills as bill
    where bill.id = target_bill_id
      and bill.household_id = target_household_id
      and bill.owner_user_id = (select auth.uid())
      and public.can_manage_household_balance(bill.household_id, bill.balance_key)
  );
$$;

-- Nama constraint dapat berbeda pada database yang pernah dimigrasikan.
-- Hapus seluruh CHECK khusus entity_type sebelum memasang versi terbaru.
do $$
declare
  constraint_item record;
begin
  for constraint_item in
    select constraint_name.conname
    from pg_catalog.pg_constraint as constraint_name
    where constraint_name.conrelid = 'public.audit_logs'::regclass
      and constraint_name.contype = 'c'
      and pg_catalog.pg_get_constraintdef(constraint_name.oid) ilike '%entity_type%'
  loop
    execute format('alter table public.audit_logs drop constraint %I', constraint_item.conname);
  end loop;
end;
$$;

alter table public.audit_logs
  add constraint audit_logs_entity_type_check
  check (entity_type in ('transaction', 'asset', 'transfer', 'adjustment', 'monthly_bill', 'bill_payment'));

create or replace function public.write_monthly_bill_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  record_household_id uuid;
  record_user_id uuid;
  record_action text;
  record_entity_id uuid;
  record_summary text;
  record_details jsonb;
  bill_name text;
begin
  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.owner_user_id else new.owner_user_id end);
  record_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
  record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
  bill_name := case when tg_op = 'DELETE' then old.name else new.name end;
  record_summary := 'Tagihan ' || bill_name ||
    case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
  record_details := jsonb_build_object(
    'before', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    'after', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  -- Audit tidak boleh membatalkan penyimpanan tagihan utama.
  begin
    insert into public.audit_logs (
      household_id, user_id, action, entity_type, entity_id, summary, details
    ) values (
      record_household_id, record_user_id, record_action, 'monthly_bill',
      record_entity_id, left(record_summary, 180), record_details
    );
  exception when others then
    raise warning 'Audit tagihan bulanan gagal: %', sqlerrm;
  end;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.write_monthly_bill_payment_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  record_household_id uuid;
  record_user_id uuid;
  record_entity_id uuid;
  record_summary text;
  record_details jsonb;
  bill_name text;
begin
  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(auth.uid(), case when tg_op = 'DELETE' then old.marked_by else new.marked_by end);
  record_entity_id := case when tg_op = 'DELETE' then old.monthly_bill_id else new.monthly_bill_id end;

  select bill.name
  into bill_name
  from public.monthly_bills as bill
  where bill.id = record_entity_id;

  bill_name := coalesce(bill_name, 'Bulanan');
  record_summary := 'Tagihan ' || bill_name ||
    case when tg_op = 'INSERT' then ' ditandai sudah dibayar' else ' ditandai belum dibayar' end;
  record_details := jsonb_build_object(
    'bill_name', bill_name,
    'before', case when tg_op = 'DELETE' then to_jsonb(old) else null end,
    'after', case when tg_op = 'INSERT' then to_jsonb(new) else null end
  );

  -- Sama seperti tagihan, kegagalan audit tidak boleh mengubah status checklist.
  begin
    insert into public.audit_logs (
      household_id, user_id, action, entity_type, entity_id, summary, details
    ) values (
      record_household_id, record_user_id, 'update', 'bill_payment',
      record_entity_id, left(record_summary, 180), record_details
    );
  exception when others then
    raise warning 'Audit status tagihan gagal: %', sqlerrm;
  end;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists audit_monthly_bills_trigger on public.monthly_bills;
create trigger audit_monthly_bills_trigger
after insert or update or delete on public.monthly_bills
for each row execute function public.write_monthly_bill_audit_log();

drop trigger if exists audit_monthly_bill_payments_trigger on public.monthly_bill_payments;
create trigger audit_monthly_bill_payments_trigger
after insert or delete on public.monthly_bill_payments
for each row execute function public.write_monthly_bill_payment_audit_log();

alter table public.monthly_bills enable row level security;
alter table public.monthly_bill_payments enable row level security;

drop policy if exists "Members can read monthly bills" on public.monthly_bills;
create policy "Members can read monthly bills"
on public.monthly_bills
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Owners can add their monthly bills" on public.monthly_bills;
create policy "Owners can add their monthly bills"
on public.monthly_bills
for insert
to authenticated
with check (
  owner_user_id = (select auth.uid())
  and (select public.can_manage_household_balance(household_id, balance_key))
);

drop policy if exists "Owners can update their monthly bills" on public.monthly_bills;
create policy "Owners can update their monthly bills"
on public.monthly_bills
for update
to authenticated
using (
  owner_user_id = (select auth.uid())
  and (select public.can_manage_household_balance(household_id, balance_key))
)
with check (
  owner_user_id = (select auth.uid())
  and (select public.can_manage_household_balance(household_id, balance_key))
);

drop policy if exists "Owners can delete their monthly bills" on public.monthly_bills;
create policy "Owners can delete their monthly bills"
on public.monthly_bills
for delete
to authenticated
using (
  owner_user_id = (select auth.uid())
  and (select public.can_manage_household_balance(household_id, balance_key))
);

drop policy if exists "Members can read bill payments" on public.monthly_bill_payments;
create policy "Members can read bill payments"
on public.monthly_bill_payments
for select
to authenticated
using ((select public.is_household_member(household_id)));

drop policy if exists "Owners can mark their bills paid" on public.monthly_bill_payments;
create policy "Owners can mark their bills paid"
on public.monthly_bill_payments
for insert
to authenticated
with check (
  marked_by = (select auth.uid())
  and (select public.can_manage_monthly_bill(monthly_bill_id, household_id))
);

drop policy if exists "Owners can unmark their bills paid" on public.monthly_bill_payments;
create policy "Owners can unmark their bills paid"
on public.monthly_bill_payments
for delete
to authenticated
using (
  marked_by = (select auth.uid())
  and (select public.can_manage_monthly_bill(monthly_bill_id, household_id))
);

revoke all on public.monthly_bills from public, anon, authenticated;
revoke all on public.monthly_bill_payments from public, anon, authenticated;

grant select, insert, update, delete on public.monthly_bills to authenticated;
grant select, insert, delete on public.monthly_bill_payments to authenticated;

revoke execute on function public.set_monthly_bill_updated_at() from public, anon, authenticated;
revoke execute on function public.can_manage_household_balance(uuid, text) from public, anon;
revoke execute on function public.can_manage_monthly_bill(uuid, uuid) from public, anon;
revoke execute on function public.write_monthly_bill_audit_log() from public, anon, authenticated;
revoke execute on function public.write_monthly_bill_payment_audit_log() from public, anon, authenticated;

grant execute on function public.can_manage_household_balance(uuid, text) to authenticated;
grant execute on function public.can_manage_monthly_bill(uuid, uuid) to authenticated;

commit;

-- Minta PostgREST/Supabase membaca ulang tabel, kolom, function, dan policy.
notify pgrst, 'reload schema';

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
