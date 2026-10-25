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
