-- Hostel Meal Management: ALL migrations (001-006) in one file. Paste into Supabase SQL Editor and Run once.

-- ===================== 001_core_schema.sql =====================
-- Hostel Meal Management: core schema, RLS, atomic financial functions
-- Run in Supabase SQL editor (or as migration). Amounts are integer poisha (৳1 = 100).

create extension if not exists pgcrypto;

-- ===== Enums =====
create type user_role as enum ('super_admin','batch_admin','student');
create type meal_type as enum ('lunch','dinner');
create type booking_status as enum ('booked','cancelled','consumed','missed','authorized_exception');
create type txn_type as enum ('opening','deposit','refund','credit_adj','debit_adj','meal_charge','reversal');

-- ===== Core tables =====
create table batches (
  id serial primary key,
  name text not null unique,
  is_active boolean not null default true
);

create table profiles (               -- one row per auth user
  id uuid primary key references auth.users(id) on delete restrict,
  full_name text not null,
  role user_role not null default 'student',
  is_active boolean not null default true
);

create table students (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references profiles(id),
  student_code text not null unique,
  roll_no text,
  batch_id int not null references batches(id),
  status text not null default 'active' check (status in ('active','suspended','inactive'))
);
create index on students(batch_id);

create table admin_batches (          -- batch admin <-> batch assignment
  admin_id uuid references profiles(id) on delete cascade,
  batch_id int references batches(id) on delete cascade,
  primary key (admin_id, batch_id)
);

create table settings (
  key text primary key,
  value text not null
);
insert into settings values
  ('timezone','Asia/Dhaka'),
  ('booking_deadline','22:00'),
  ('allow_negative','false');

create table meal_prices (            -- effective-dated; history never altered
  id serial primary key,
  meal meal_type not null,
  price int not null check (price > 0),
  effective_from date not null,
  created_by uuid references profiles(id),
  unique (meal, effective_from)
);
insert into meal_prices (meal, price, effective_from) values
  ('lunch', 4000, '2026-01-01'), ('dinner', 3500, '2026-01-01');  -- sample ৳40 / ৳35

create table meal_bookings (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  meal_date date not null,
  meal meal_type not null,
  status booking_status not null default 'booked',
  reserved_amount int not null default 0,
  exception_id uuid,
  override_by uuid references profiles(id),
  override_reason text,
  updated_at timestamptz not null default now(),
  unique (student_id, meal_date, meal)          -- no duplicate bookings
);
create index on meal_bookings(meal_date, meal);

create table authorized_exceptions (  -- negative-balance approvals
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  meal_date date not null,
  meal meal_type,                      -- null = both meals
  amount int not null check (amount > 0),
  authorized_by uuid not null references profiles(id),
  reason text not null check (length(reason) > 3),
  created_at timestamptz not null default now()
);
alter table meal_bookings add foreign key (exception_id) references authorized_exceptions(id);

-- ===== Ledger (single source of truth) =====
create table wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  type txn_type not null,
  delta bigint not null check (delta <> 0),    -- +credit / -debit
  method text,                                 -- cash, bkash, nagad, bank, ...
  reference text,
  booking_id uuid references meal_bookings(id),
  reverses_id uuid unique references wallet_transactions(id),
  exception_id uuid references authorized_exceptions(id),
  created_by uuid references profiles(id),
  note text,
  created_at timestamptz not null default now()
);
create index on wallet_transactions(student_id, created_at);
create unique index one_charge_per_booking on wallet_transactions(booking_id) where type = 'meal_charge';

create table meal_consumptions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references meal_bookings(id),  -- finalize once
  student_id uuid not null references students(id),
  meal_date date not null,
  meal meal_type not null,
  price int not null,
  confirmed_by uuid not null references profiles(id),
  confirmed_at timestamptz not null default now(),
  unique (student_id, meal_date, meal)
);

create table audit_logs (
  id bigserial primary key,
  actor uuid references profiles(id),
  action text not null,
  target_student uuid,
  details jsonb,
  created_at timestamptz not null default now()
);

-- ===== Immutability: ledger/consumption/audit can't be edited or deleted =====
create function forbid_change() returns trigger language plpgsql as $$
begin raise exception 'Immutable table: use reversal/adjustment'; end $$;
create trigger ledger_immutable before update or delete on wallet_transactions
  for each row execute function forbid_change();
create trigger consumption_immutable before update or delete on meal_consumptions
  for each row execute function forbid_change();
create trigger audit_immutable before update or delete on audit_logs
  for each row execute function forbid_change();

-- ===== Authorization helpers =====
create function my_role() returns user_role language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and is_active $$;

create function can_access_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from students s where s.id = sid and (
      my_role() = 'super_admin'
      or s.user_id = auth.uid()
      or (my_role() = 'batch_admin' and exists (
            select 1 from admin_batches ab where ab.admin_id = auth.uid() and ab.batch_id = s.batch_id))
    )) $$;

create function is_admin_for(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() in ('super_admin','batch_admin') and can_access_student(sid) $$;

-- ===== Balance helpers =====
create function current_balance(sid uuid) returns bigint language sql stable as $$
  select coalesce(sum(delta),0) from wallet_transactions where student_id = sid $$;

create function reserved_amount(sid uuid, exclude_date date default null) returns bigint
language sql stable as $$
  select coalesce(sum(reserved_amount),0) from meal_bookings
  where student_id = sid and status in ('booked','authorized_exception')
    and (exclude_date is null or meal_date <> exclude_date) $$;

create function price_on(m meal_type, d date) returns int language sql stable as $$
  select price from meal_prices where meal = m and effective_from <= d
  order by effective_from desc limit 1 $$;

create view student_wallets with (security_invoker = true) as
select s.id as student_id, s.student_code, s.batch_id,
       current_balance(s.id) as balance,
       reserved_amount(s.id) as reserved,
       current_balance(s.id) - reserved_amount(s.id) as available
from students s;

-- ===== Booking (deadline + available-balance check, race-safe) =====
create function book_meals(p_student uuid, p_date date, p_meals meal_type[],
                           p_override_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  tz text := (select value from settings where key='timezone');
  deadline timestamptz := ((p_date - 1)::text || ' ' || (select value from settings where key='booking_deadline'))::timestamp at time zone tz;
  admin boolean := is_admin_for(p_student);
  need int := 0; m meal_type; avail bigint; ex authorized_exceptions;
begin
  if not can_access_student(p_student) then raise exception 'Not allowed'; end if;
  perform 1 from students where id = p_student for update;       -- serialize per student
  if p_date <= (now() at time zone tz)::date then raise exception 'Can book future dates only'; end if;
  if now() >= deadline then
    if not admin then raise exception 'Booking locked: deadline passed (10:00 PM BST)'; end if;
    if coalesce(length(p_override_reason),0) < 4 then raise exception 'Override reason required'; end if;
  end if;

  select * into ex from authorized_exceptions
   where student_id = p_student and meal_date = p_date order by created_at desc limit 1;

  foreach m in array p_meals loop need := need + price_on(m, p_date); end loop;
  avail := current_balance(p_student) - reserved_amount(p_student, p_date);
  if avail < need and not (ex.id is not null and avail + ex.amount >= need) then
    raise exception 'Insufficient balance: shortfall % poisha', need - avail;
  end if;

  update meal_bookings set status = 'cancelled', reserved_amount = 0, updated_at = now()
   where student_id = p_student and meal_date = p_date and status in ('booked','authorized_exception')
     and meal <> all (p_meals);
  foreach m in array p_meals loop
    insert into meal_bookings (student_id, meal_date, meal, status, reserved_amount, exception_id,
                               override_by, override_reason)
    values (p_student, p_date, m,
            case when avail < need then 'authorized_exception' else 'booked' end,
            price_on(m, p_date), ex.id,
            case when now() >= deadline then auth.uid() end, p_override_reason)
    on conflict (student_id, meal_date, meal) do update
      set status = excluded.status, reserved_amount = excluded.reserved_amount,
          exception_id = excluded.exception_id, updated_at = now()
      where meal_bookings.status not in ('consumed','missed');
  end loop;
end $$;

-- ===== Confirm consumption -> single charge =====
create function confirm_consumption(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b meal_bookings; pr int; cid uuid;
begin
  select * into b from meal_bookings where id = p_booking for update;
  if not found or not is_admin_for(b.student_id) then raise exception 'Not allowed'; end if;
  if b.status not in ('booked','authorized_exception') then raise exception 'Booking not confirmable (%).', b.status; end if;
  perform 1 from students where id = b.student_id for update;
  pr := price_on(b.meal, b.meal_date);                     -- price effective on meal date
  insert into meal_consumptions (booking_id, student_id, meal_date, meal, price, confirmed_by)
    values (b.id, b.student_id, b.meal_date, b.meal, pr, auth.uid());
  insert into wallet_transactions (student_id, type, delta, booking_id, exception_id, created_by)
    values (b.student_id, 'meal_charge', -pr, b.id, b.exception_id, auth.uid());
  update meal_bookings set status = 'consumed', reserved_amount = 0, updated_at = now() where id = b.id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'confirm_consumption', b.student_id, jsonb_build_object('booking', b.id, 'price', pr));
end $$;

-- ===== Deposits / adjustments (admin only, batch-checked) =====
create function post_transaction(p_student uuid, p_type txn_type, p_amount int,
                                 p_method text, p_ref text, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid; d bigint;
begin
  if not is_admin_for(p_student) then raise exception 'Not allowed'; end if;
  if p_type not in ('deposit','refund','credit_adj','debit_adj') then raise exception 'Invalid type'; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if p_type in ('debit_adj','refund') and my_role() <> 'super_admin' and p_amount > 50000 then
    raise exception 'Exceeds batch-admin limit; Super Admin authorization required'; end if;
  d := case when p_type in ('deposit','credit_adj') then p_amount else -p_amount end;
  perform 1 from students where id = p_student for update;
  insert into wallet_transactions (student_id, type, delta, method, reference, created_by, note)
    values (p_student, p_type, d, p_method, p_ref, auth.uid(), p_note) returning wallet_transactions.id into id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'post_'||p_type, p_student, jsonb_build_object('txn', id, 'amount', p_amount));
  return id;
end $$;

-- ===== Reversal (one per transaction) =====
create function reverse_transaction(p_txn uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t wallet_transactions; id uuid;
begin
  select * into t from wallet_transactions where id = p_txn;
  if not found or not is_admin_for(t.student_id) then raise exception 'Not allowed'; end if;
  if t.type = 'reversal' then raise exception 'Cannot reverse a reversal'; end if;
  insert into wallet_transactions (student_id, type, delta, reverses_id, created_by, note)
    values (t.student_id, 'reversal', -t.delta, t.id, auth.uid(), p_reason) returning wallet_transactions.id into id;
  if t.type = 'meal_charge' then   -- reopen meal so it can be re-verified
    update meal_bookings set status = 'booked', reserved_amount = price_on(meal, meal_date) where id = t.booking_id;
  end if;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'reverse', t.student_id, jsonb_build_object('txn', t.id, 'reason', p_reason));
  return id;
end $$;
-- NOTE: meal_consumptions row is immutable; a re-confirm after reversal needs the
-- consumption-supersede flow (listed as TODO in README).

-- ===== Row-level security =====
alter table batches enable row level security;
alter table profiles enable row level security;
alter table students enable row level security;
alter table admin_batches enable row level security;
alter table settings enable row level security;
alter table meal_prices enable row level security;
alter table meal_bookings enable row level security;
alter table authorized_exceptions enable row level security;
alter table wallet_transactions enable row level security;
alter table meal_consumptions enable row level security;
alter table audit_logs enable row level security;

create policy read_batches on batches for select using (auth.uid() is not null);
create policy read_prices on meal_prices for select using (auth.uid() is not null);
create policy read_settings on settings for select using (auth.uid() is not null);
create policy super_prices on meal_prices for all using (my_role()='super_admin') with check (my_role()='super_admin');
create policy super_settings on settings for all using (my_role()='super_admin') with check (my_role()='super_admin');
create policy super_batches on batches for all using (my_role()='super_admin') with check (my_role()='super_admin');

create policy read_profile on profiles for select using (id = auth.uid() or my_role()='super_admin');
create policy super_profiles on profiles for all using (my_role()='super_admin') with check (my_role()='super_admin');
create policy read_students on students for select using (can_access_student(id));
create policy super_students on students for all using (my_role()='super_admin') with check (my_role()='super_admin');
create policy read_assign on admin_batches for select using (admin_id = auth.uid() or my_role()='super_admin');
create policy super_assign on admin_batches for all using (my_role()='super_admin') with check (my_role()='super_admin');

create policy read_bookings on meal_bookings for select using (can_access_student(student_id));
create policy read_txns on wallet_transactions for select using (can_access_student(student_id));
create policy read_consumption on meal_consumptions for select using (can_access_student(student_id));
create policy read_exceptions on authorized_exceptions for select using (can_access_student(student_id));
create policy read_audit on audit_logs for select using (my_role()='super_admin');
-- Exceptions created only by Super Admin (or batch admin if you extend policy):
create policy super_exceptions on authorized_exceptions for insert
  with check (my_role()='super_admin' and authorized_by = auth.uid());

-- No direct writes to bookings / ledger / consumption: only via security-definer functions.
revoke insert, update, delete on meal_bookings, wallet_transactions, meal_consumptions, audit_logs from anon, authenticated;
revoke execute on all functions in schema public from anon;

-- ===================== 002_missed_and_reversal.sql =====================
-- Run after 001_core_schema.sql. Adds missed-meal marking and re-confirmable reversals.

-- 1) Consumption rows: allow ONLY setting reversed_at (null -> timestamp); uniqueness applies to unreversed rows.
alter table meal_consumptions add column reversed_at timestamptz;
alter table meal_consumptions drop constraint meal_consumptions_booking_id_key;
alter table meal_consumptions drop constraint meal_consumptions_student_id_meal_date_meal_key;
create unique index one_live_consumption_per_booking on meal_consumptions(booking_id) where reversed_at is null;
create unique index one_live_consumption_per_meal on meal_consumptions(student_id, meal_date, meal) where reversed_at is null;

create or replace function guard_consumption() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.reversed_at is null and new.reversed_at is not null
     and (new.id, new.booking_id, new.student_id, new.meal_date, new.meal, new.price, new.confirmed_by, new.confirmed_at)
         is not distinct from
         (old.id, old.booking_id, old.student_id, old.meal_date, old.meal, old.price, old.confirmed_by, old.confirmed_at)
  then return new; end if;
  raise exception 'Immutable table: only reversal marking is allowed';
end $$;
drop trigger consumption_immutable on meal_consumptions;
create trigger consumption_guard before update or delete on meal_consumptions
  for each row execute function guard_consumption();

-- 2) One charge per consumption (not per booking), so a reversed meal can be re-confirmed.
alter table wallet_transactions add column consumption_id uuid references meal_consumptions(id);
drop index one_charge_per_booking;
create unique index one_charge_per_consumption on wallet_transactions(consumption_id) where type = 'meal_charge';

create or replace function confirm_consumption(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b meal_bookings; pr int; cid uuid;
begin
  select * into b from meal_bookings where id = p_booking for update;
  if not found or not is_admin_for(b.student_id) then raise exception 'Not allowed'; end if;
  if b.status not in ('booked','authorized_exception') then raise exception 'Booking not confirmable (%).', b.status; end if;
  perform 1 from students where id = b.student_id for update;
  pr := price_on(b.meal, b.meal_date);
  insert into meal_consumptions (booking_id, student_id, meal_date, meal, price, confirmed_by)
    values (b.id, b.student_id, b.meal_date, b.meal, pr, auth.uid()) returning id into cid;
  insert into wallet_transactions (student_id, type, delta, booking_id, consumption_id, exception_id, created_by)
    values (b.student_id, 'meal_charge', -pr, b.id, cid, b.exception_id, auth.uid());
  update meal_bookings set status = 'consumed', reserved_amount = 0, updated_at = now() where id = b.id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'confirm_consumption', b.student_id, jsonb_build_object('booking', b.id, 'price', pr));
end $$;

create or replace function reverse_transaction(p_txn uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t wallet_transactions; id uuid;
begin
  select * into t from wallet_transactions where id = p_txn;
  if not found or not is_admin_for(t.student_id) then raise exception 'Not allowed'; end if;
  if t.type = 'reversal' then raise exception 'Cannot reverse a reversal'; end if;
  if coalesce(length(p_reason),0) < 4 then raise exception 'Reason required'; end if;
  perform 1 from students where id = t.student_id for update;
  insert into wallet_transactions (student_id, type, delta, reverses_id, created_by, note)
    values (t.student_id, 'reversal', -t.delta, t.id, auth.uid(), p_reason) returning wallet_transactions.id into id;
  if t.type = 'meal_charge' then
    update meal_consumptions set reversed_at = now() where id = t.consumption_id;
    update meal_bookings set status = 'booked', reserved_amount = price_on(meal, meal_date), updated_at = now()
      where id = t.booking_id;
  end if;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'reverse', t.student_id, jsonb_build_object('txn', t.id, 'reason', p_reason));
  return id;
end $$;

-- 3) Reverse the live charge of a consumed booking (used by the admin UI)
create function reverse_meal_charge(p_booking uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid; sid uuid;
begin
  select student_id into sid from meal_bookings where id = p_booking;
  if sid is null or not is_admin_for(sid) then raise exception 'Not allowed'; end if;
  select w.id into t from wallet_transactions w
    join meal_consumptions c on c.id = w.consumption_id
   where w.booking_id = p_booking and w.type = 'meal_charge' and c.reversed_at is null;
  if t is null then raise exception 'No live charge for this booking'; end if;
  return reverse_transaction(t, p_reason);
end $$;

-- 4) Missed meal: never charged
create function mark_missed(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b meal_bookings;
begin
  select * into b from meal_bookings where id = p_booking for update;
  if not found or not is_admin_for(b.student_id) then raise exception 'Not allowed'; end if;
  if b.status not in ('booked','authorized_exception') then raise exception 'Cannot mark missed (%).', b.status; end if;
  update meal_bookings set status = 'missed', reserved_amount = 0, updated_at = now() where id = p_booking;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'mark_missed', b.student_id, jsonb_build_object('booking', b.id));
end $$;

revoke execute on function mark_missed(uuid), reverse_meal_charge(uuid, text) from anon;

-- ===================== 003_exceptions.sql =====================
-- Run after 002. Negative-balance exceptions: Super Admin only, via a server function, always audited.

create function authorize_exception(p_student uuid, p_date date, p_meal meal_type, p_amount int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Only a Super Admin can authorize exceptions'; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if coalesce(length(p_reason),0) < 4 then raise exception 'Reason required'; end if;
  if not exists (select 1 from students where id = p_student and status = 'active') then
    raise exception 'Student not active'; end if;
  insert into authorized_exceptions (student_id, meal_date, meal, amount, authorized_by, reason)
    values (p_student, p_date, p_meal, p_amount, auth.uid(), p_reason) returning authorized_exceptions.id into id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'authorize_exception', p_student,
            jsonb_build_object('exception', id, 'date', p_date, 'meal', p_meal, 'amount', p_amount, 'reason', p_reason));
  return id;
end $$;

-- No direct inserts any more: the function is the only path.
drop policy super_exceptions on authorized_exceptions;
revoke insert, update, delete on authorized_exceptions from anon, authenticated;
revoke execute on function authorize_exception(uuid, date, meal_type, int, text) from anon;

-- ===================== 004_pricing_settings.sql =====================
-- Run after 003. Price and deadline changes go through audited Super-Admin functions only.

create function set_meal_price(p_meal meal_type, p_price int, p_from date) returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone (select value from settings where key = 'timezone'))::date;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_price <= 0 then raise exception 'Price must be positive'; end if;
  if p_from < today then raise exception 'Effective date cannot be in the past'; end if;
  if exists (select 1 from meal_prices where meal = p_meal and effective_from = p_from and effective_from <= today) then
    raise exception 'A price already took effect on that date; choose a later date'; end if;
  insert into meal_prices (meal, price, effective_from, created_by) values (p_meal, p_price, p_from, auth.uid())
    on conflict (meal, effective_from) do update set price = excluded.price, created_by = auth.uid();
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_meal_price', jsonb_build_object('meal', p_meal, 'price', p_price, 'from', p_from));
end $$;

create function set_booking_deadline(p_time text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Use 24-hour HH:MM'; end if;
  update settings set value = p_time where key = 'booking_deadline';
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_booking_deadline', jsonb_build_object('time', p_time));
end $$;

drop policy super_prices on meal_prices;
drop policy super_settings on settings;
revoke insert, update, delete on meal_prices, settings from anon, authenticated;
revoke execute on function set_meal_price(meal_type, int, date), set_booking_deadline(text) from anon;

-- ===================== 005_reports.sql =====================
-- Run after 004. Reports and reconciliation. SECURITY INVOKER: RLS applies, so batch admins only see their batches.

-- Fix: admins must be able to read the names of students they can access.
create policy read_student_profiles on profiles for select
  using (exists (select 1 from students s where s.user_id = profiles.id and can_access_student(s.id)));

create function student_ledger_report(p_from date, p_to date, p_batch int default null)
returns table (student_id uuid, student_code text, full_name text, batch text,
  opening bigint, deposits bigint, refunds bigint, credit_adj bigint, debit_adj bigint,
  meal_charges bigint, reversals bigint, closing bigint, meals_booked int, meals_consumed int)
language sql stable as $$
  select s.id, s.student_code, p.full_name, b.name,
    coalesce(sum(t.delta) filter (where t.d < p_from), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'deposit'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'refund'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'credit_adj'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'debit_adj'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'meal_charge'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'reversal'), 0),
    coalesce(sum(t.delta) filter (where t.d <= p_to), 0),
    (select count(*) from meal_bookings mb where mb.student_id = s.id and mb.meal_date between p_from and p_to
       and mb.status <> 'cancelled')::int,
    (select count(*) from meal_consumptions c where c.student_id = s.id and c.meal_date between p_from and p_to
       and c.reversed_at is null)::int
  from students s
  join batches b on b.id = s.batch_id
  left join profiles p on p.id = s.user_id
  left join lateral (select w.type, w.delta, (w.created_at at time zone 'Asia/Dhaka')::date as d
                     from wallet_transactions w where w.student_id = s.id) t on true
  where p_batch is null or s.batch_id = p_batch
  group by s.id, s.student_code, p.full_name, b.name
  order by b.name, s.student_code $$;

-- Note: opening balances are ledger rows of type 'opening' (counted in "opening" if dated before the range).

create function reconciliation_report()
returns table (check_name text, student_code text, detail text)
language sql stable as $$
  select 'Consumption without live charge', s.student_code, c.meal_date || ' ' || c.meal
    from meal_consumptions c join students s on s.id = c.student_id
   where c.reversed_at is null
     and not exists (select 1 from wallet_transactions w where w.consumption_id = c.id and w.type = 'meal_charge')
  union all
  select 'Charge without valid consumption', s.student_code, w.created_at::date || ' ' || w.delta
    from wallet_transactions w join students s on s.id = w.student_id
    left join meal_consumptions c on c.id = w.consumption_id
   where w.type = 'meal_charge'
     and not exists (select 1 from wallet_transactions r where r.reverses_id = w.id)
     and (c.id is null or c.reversed_at is not null)
  union all
  select 'Possible duplicate deposit', s.student_code, d.method || ' / ' || d.reference || ' x' || d.n
    from (select w.student_id, w.method, w.reference, count(*) n from wallet_transactions w
           where w.type = 'deposit' and w.reference is not null
             and not exists (select 1 from wallet_transactions r where r.reverses_id = w.id)
           group by 1, 2, 3 having count(*) > 1) d
    join students s on s.id = d.student_id
  union all
  select 'Unsettled reservation', s.student_code, mb.meal_date || ' ' || mb.meal
    from meal_bookings mb join students s on s.id = mb.student_id
   where mb.reserved_amount > 0 and mb.status in ('booked', 'authorized_exception')
     and mb.meal_date < (now() at time zone 'Asia/Dhaka')::date
  union all
  select 'Negative balance without any exception', s.student_code, current_balance(s.id)::text
    from students s
   where current_balance(s.id) < 0
     and not exists (select 1 from authorized_exceptions e where e.student_id = s.id)
  union all
  select 'Multiple opening balances', s.student_code, count(*)::text
    from wallet_transactions w join students s on s.id = w.student_id
   where w.type = 'opening' group by s.student_code having count(*) > 1
  union all
  select 'Adjustment without admin author', s.student_code, w.type || ' ' || w.delta
    from wallet_transactions w join students s on s.id = w.student_id
   where w.type in ('credit_adj', 'debit_adj')
     and (w.created_by is null or not exists (select 1 from profiles p where p.id = w.created_by
          and p.role in ('super_admin', 'batch_admin'))) $$;

revoke execute on function student_ledger_report(date, date, int), reconciliation_report() from anon;

-- ===================== 006_management.sql =====================
-- Run after 005. Audited Super-Admin management functions. Account creation is done by the server-only API route.

create function upsert_batch(p_id int, p_name text, p_active boolean) returns int
language plpgsql security definer set search_path = public as $$
declare rid int;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if coalesce(length(trim(p_name)),0) < 2 then raise exception 'Batch name required'; end if;
  if p_id is null then
    insert into batches (name, is_active) values (trim(p_name), coalesce(p_active, true)) returning id into rid;
  else
    update batches set name = trim(p_name), is_active = coalesce(p_active, is_active) where id = p_id returning id into rid;
    if rid is null then raise exception 'Batch not found'; end if;
  end if;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'upsert_batch', jsonb_build_object('batch', rid, 'name', p_name, 'active', p_active));
  return rid;
end $$;

create function set_student_status(p_student uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_status not in ('active','suspended','inactive') then raise exception 'Invalid status'; end if;
  update students set status = p_status where id = p_student;
  if not found then raise exception 'Student not found'; end if;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'set_student_status', p_student, jsonb_build_object('status', p_status));
end $$;

create function set_admin_batches(p_admin uuid, p_batches int[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if not exists (select 1 from profiles where id = p_admin and role = 'batch_admin') then
    raise exception 'Target is not a batch admin'; end if;
  delete from admin_batches where admin_id = p_admin;
  insert into admin_batches (admin_id, batch_id) select p_admin, b from unnest(p_batches) b;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_admin_batches', jsonb_build_object('admin', p_admin, 'batches', p_batches));
end $$;

create function set_user_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own account status'; end if;
  update profiles set is_active = p_active where id = p_user;
  if not found then raise exception 'User not found'; end if;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_user_active', jsonb_build_object('user', p_user, 'active', p_active));
end $$;

-- All writes now go through the functions above (or the service-role API route).
drop policy super_batches on batches;
drop policy super_students on students;
drop policy super_assign on admin_batches;
drop policy super_profiles on profiles;
revoke insert, update, delete on batches, students, admin_batches, profiles from anon, authenticated;
revoke execute on function upsert_batch(int, text, boolean), set_student_status(uuid, text),
  set_admin_batches(uuid, int[]), set_user_active(uuid, boolean) from anon;
