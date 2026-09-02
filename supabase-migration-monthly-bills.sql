-- ============================================================
-- KEUANGAN KITA — Tagihan bulanan dan status pembayaran
-- Jalankan setelah supabase-migration-transfers-logs.sql.
-- ============================================================

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

alter table public.audit_logs
  drop constraint if exists audit_logs_entity_type_check;

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
  record_entity_type text;
  record_entity_id uuid;
  record_summary text;
  record_details jsonb;
  bill_name text;
begin
  record_household_id := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  record_user_id := coalesce(
    auth.uid(),
    case
      when tg_table_name = 'monthly_bills' and tg_op = 'DELETE' then old.owner_user_id
      when tg_table_name = 'monthly_bills' then new.owner_user_id
      when tg_op = 'DELETE' then old.marked_by
      else new.marked_by
    end
  );

  if tg_table_name = 'monthly_bills' then
    record_entity_type := 'monthly_bill';
    record_entity_id := case when tg_op = 'DELETE' then old.id else new.id end;
    record_action := case when tg_op = 'INSERT' then 'create' else lower(tg_op) end;
    bill_name := case when tg_op = 'DELETE' then old.name else new.name end;
    record_summary := 'Tagihan ' || bill_name ||
      case tg_op when 'INSERT' then ' ditambahkan' when 'UPDATE' then ' diubah' else ' dihapus' end;
    record_details := jsonb_build_object(
      'before', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
      'after', case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
    );
  else
    record_entity_type := 'bill_payment';
    record_entity_id := case when tg_op = 'DELETE' then old.monthly_bill_id else new.monthly_bill_id end;
    record_action := 'update';

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
  end if;

  insert into public.audit_logs (
    household_id, user_id, action, entity_type, entity_id, summary, details
  ) values (
    record_household_id, record_user_id, record_action, record_entity_type,
    record_entity_id, left(record_summary, 180), record_details
  );

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
for each row execute function public.write_monthly_bill_audit_log();

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

grant execute on function public.can_manage_household_balance(uuid, text) to authenticated;
grant execute on function public.can_manage_monthly_bill(uuid, uuid) to authenticated;
