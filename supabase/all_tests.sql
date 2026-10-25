-- TEST DATA + ALL TESTS in one file. Run once in Supabase SQL Editor (after all_migrations.sql).
-- Success with no red error = every test passed. An error names the failing test.

-- ===================== seed_test.sql =====================
-- TEST DATA ONLY. Never run on production. Run after 001_core_schema.sql.
-- All test users have password: Test@12345

insert into batches (name) select 'Batch ' || n from generate_series(11,16) n
on conflict (name) do nothing;

do $$
declare
  r record;
begin
  for r in select * from (values
    ('00000000-0000-0000-0000-000000000001'::uuid, 'super@test.local',   'Test Super Admin', 'super_admin'),
    ('00000000-0000-0000-0000-000000000011'::uuid, 'admin11@test.local', 'Test Admin B11',   'batch_admin'),
    ('00000000-0000-0000-0000-000000000012'::uuid, 'admin12@test.local', 'Test Admin B12',   'batch_admin'),
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'student1@test.local','Test Student One', 'student'),
    ('00000000-0000-0000-0000-0000000000a2'::uuid, 'student2@test.local','Test Student Two', 'student')
  ) as t(id, email, full_name, role)
  loop
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email,
      crypt('Test@12345', gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '')
    on conflict (id) do nothing;

    insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at, last_sign_in_at)
    values (gen_random_uuid(), r.id, r.id::text,
      jsonb_build_object('sub', r.id::text, 'email', r.email), 'email', now(), now(), now())
    on conflict do nothing;

    insert into profiles (id, full_name, role) values (r.id, r.full_name, r.role::user_role)
    on conflict (id) do nothing;
  end loop;
end $$;

insert into admin_batches (admin_id, batch_id)
select '00000000-0000-0000-0000-000000000011', id from batches where name = 'Batch 11'
on conflict do nothing;
insert into admin_batches (admin_id, batch_id)
select '00000000-0000-0000-0000-000000000012', id from batches where name = 'Batch 12'
on conflict do nothing;

insert into students (id, user_id, student_code, roll_no, batch_id)
select '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'T-1101', '1', id
  from batches where name = 'Batch 11' on conflict do nothing;
insert into students (id, user_id, student_code, roll_no, batch_id)
select '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a2', 'T-1102', '2', id
  from batches where name = 'Batch 11' on conflict do nothing;

-- Student One starts with ৳100 (10000 poisha); Student Two with ৳0
insert into wallet_transactions (student_id, type, delta, note)
select '00000000-0000-0000-0000-0000000000b1', 'opening', 10000, 'test opening balance'
where not exists (select 1 from wallet_transactions where student_id = '00000000-0000-0000-0000-0000000000b1');

-- ===================== tests.sql =====================
-- Financial logic tests. Run in Supabase SQL editor AFTER seed_test.sql.
-- Runs in one transaction and ROLLS BACK, so nothing is saved.
-- A failed check raises an exception with the test name.
begin;

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;

create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'FAIL: %', name; end if;
  raise notice 'PASS: %', name;
end $$;

do $$
declare
  s1 uuid := '00000000-0000-0000-0000-0000000000b1';
  s2 uuid := '00000000-0000-0000-0000-0000000000b2';
  u1 uuid := '00000000-0000-0000-0000-0000000000a1';
  u2 uuid := '00000000-0000-0000-0000-0000000000a2';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  a12 uuid := '00000000-0000-0000-0000-000000000012';
  today date := (now() at time zone 'Asia/Dhaka')::date;
  d date := (now() at time zone 'Asia/Dhaka')::date + 2;   -- deadline always still open
  tmr date := (now() at time zone 'Asia/Dhaka')::date + 1;
  bid uuid; dep uuid; n int;
begin
  -- 1 + 7: sufficient funds, booking creates no charge
  perform pg_temp.as_user(u1);
  perform book_meals(s1, d, array['lunch']::meal_type[]);
  perform pg_temp.check((select count(*) from wallet_transactions where student_id = s1 and type = 'meal_charge') = 0,
    '7 booking does not create a charge');
  perform pg_temp.check(reserved_amount(s1) = 4000, '1 lunch booked, 4000 reserved');

  -- 2: insufficient funds blocked
  perform pg_temp.as_user(u2);
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L, %L, array['lunch']::meal_type[])$q$, s2, d)),
    '2 insufficient balance cannot book');

  -- 3: both meals, available accounts for reservation
  perform pg_temp.as_user(u1);
  perform book_meals(s1, d, array['lunch','dinner']::meal_type[]);
  perform pg_temp.check(reserved_amount(s1) = 7500 and current_balance(s1) - reserved_amount(s1) = 2500,
    '3 both meals, available = balance - reserved');

  -- 5: change before deadline (cancel dinner)
  perform book_meals(s1, d, array['lunch']::meal_type[]);
  perform pg_temp.check(reserved_amount(s1) = 4000 and
    (select status from meal_bookings where student_id = s1 and meal_date = d and meal = 'dinner') = 'cancelled',
    '5 booking editable before deadline, cancelled meal releases reservation');

  -- 6: lock after deadline, admin override needs reason
  update settings set value = '00:00' where key = 'booking_deadline';
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L, %L, array['lunch']::meal_type[])$q$, s1, tmr)),
    '6 student locked after deadline');
  perform pg_temp.as_user(a11);
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L, %L, array['lunch']::meal_type[])$q$, s1, tmr)),
    '6 admin override without reason rejected');
  perform book_meals(s1, tmr, array['lunch']::meal_type[], 'student was ill, late request');
  perform pg_temp.check((select override_by from meal_bookings where student_id = s1 and meal_date = tmr) = a11,
    '6 override records admin');
  update settings set value = '22:00' where key = 'booking_deadline';

  -- 8 + 9: confirm charges once, duplicate rejected
  select id into bid from meal_bookings where student_id = s1 and meal_date = d and meal = 'lunch';
  perform confirm_consumption(bid);
  perform pg_temp.check(current_balance(s1) = 6000, '8 consumption charges 4000 once');
  perform pg_temp.check(pg_temp.fails(format('select confirm_consumption(%L)', bid)), '9 duplicate confirmation rejected');
  perform pg_temp.check((select count(*) from wallet_transactions where student_id = s1 and type = 'meal_charge') = 1,
    '9 exactly one meal charge');

  -- 12 / 15 / 16: unauthorized actors
  perform pg_temp.as_user(a12);
  perform pg_temp.check(pg_temp.fails(format('select confirm_consumption(%L)',
      (select id from meal_bookings where student_id = s1 and meal_date = tmr))),
    '16 other-batch admin cannot confirm');
  perform pg_temp.check(pg_temp.fails(format($q$select post_transaction(%L,'deposit',5000,'cash',null,null)$q$, s1)),
    '16 other-batch admin cannot deposit');
  perform pg_temp.as_user(u1);
  perform pg_temp.check(pg_temp.fails(format($q$select post_transaction(%L,'deposit',99999,'cash',null,null)$q$, s1)),
    '14 student cannot credit own wallet');
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L, %L, array['lunch']::meal_type[])$q$, s2, d)),
    '15 student cannot book for another student');

  -- 13: deposit
  perform pg_temp.as_user(a11);
  dep := post_transaction(s1, 'deposit', 5000, 'bkash', 'TX123', 'test');
  perform pg_temp.check(current_balance(s1) = 11000, '13 deposit updates balance');

  -- 17: price change leaves history untouched
  insert into meal_prices (meal, price, effective_from) values ('lunch', 5000, d + 1);
  perform pg_temp.check(price_on('lunch', d) = 4000 and price_on('lunch', d + 1) = 5000, '17 effective-dated prices');
  perform pg_temp.check((select price from meal_consumptions where booking_id = bid) = 4000
    and (select delta from wallet_transactions where booking_id = bid and type = 'meal_charge') = -4000,
    '17 historical charge unchanged');

  -- 18: reversal traceable, only once; ledger immutable
  perform reverse_transaction(dep, 'entered by mistake');
  perform pg_temp.check(current_balance(s1) = 6000, '18 reversal restores balance');
  perform pg_temp.check(pg_temp.fails(format($q$select reverse_transaction(%L,'again')$q$, dep)), '18 double reversal rejected');
  perform pg_temp.check(pg_temp.fails($q$update wallet_transactions set note = 'x'$q$), '18 ledger rows immutable');
  perform pg_temp.check(pg_temp.fails($q$delete from wallet_transactions$q$), '18 ledger rows cannot be deleted');

  raise notice 'ALL TESTS PASSED';
end $$;

rollback;

-- ===================== tests_002.sql =====================
-- Run after 002_missed_and_reversal.sql and seed_test.sql. Rolls back.
begin;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', name; end if; raise notice 'PASS: %', name; end $$;

do $$
declare
  s1 uuid := '00000000-0000-0000-0000-0000000000b1';
  u1 uuid := '00000000-0000-0000-0000-0000000000a1';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  a12 uuid := '00000000-0000-0000-0000-000000000012';
  d date := (now() at time zone 'Asia/Dhaka')::date + 2;
  b1 uuid; b2 uuid;
begin
  perform pg_temp.as_user(u1);
  perform book_meals(s1, d, array['lunch']::meal_type[]);
  perform book_meals(s1, d + 1, array['lunch']::meal_type[]);
  select id into b1 from meal_bookings where student_id = s1 and meal_date = d;
  select id into b2 from meal_bookings where student_id = s1 and meal_date = d + 1;

  perform pg_temp.check(pg_temp.fails(format('select mark_missed(%L)', b1)), 'student cannot mark missed');
  perform pg_temp.as_user(a12);
  perform pg_temp.check(pg_temp.fails(format('select mark_missed(%L)', b1)), 'other-batch admin cannot mark missed');

  perform pg_temp.as_user(a11);
  perform mark_missed(b1);
  perform pg_temp.check((select status from meal_bookings where id = b1) = 'missed' and current_balance(s1) = 10000
    and reserved_amount(s1) = 4000, '10 missed meal not charged, reservation released');

  perform confirm_consumption(b2);
  perform pg_temp.check(current_balance(s1) = 6000, 'charge after confirm');
  perform reverse_meal_charge(b2, 'confirmed by mistake');
  perform pg_temp.check(current_balance(s1) = 10000 and (select status from meal_bookings where id = b2) = 'booked',
    'reversal restores balance and reopens booking');
  perform confirm_consumption(b2);
  perform pg_temp.check(current_balance(s1) = 6000, 're-confirm after reversal charges once');
  perform pg_temp.check((select count(*) from meal_consumptions where booking_id = b2 and reversed_at is null) = 1
    and (select count(*) from wallet_transactions where booking_id = b2 and type = 'meal_charge') = 2
    and (select count(*) from wallet_transactions where student_id = s1 and type = 'reversal') = 1,
    'history kept: 2 charges, 1 reversal, 1 live consumption');
  perform pg_temp.check(pg_temp.fails($q$update meal_consumptions set price = 1$q$), 'consumption price immutable');
  raise notice 'ALL 002 TESTS PASSED';
end $$;
rollback;

-- ===================== tests_003.sql =====================
-- Run after 003_exceptions.sql, 002 and seed_test.sql. Rolls back.
begin;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', name; end if; raise notice 'PASS: %', name; end $$;

do $$
declare
  s2 uuid := '00000000-0000-0000-0000-0000000000b2';   -- balance 0
  u2 uuid := '00000000-0000-0000-0000-0000000000a2';
  sa uuid := '00000000-0000-0000-0000-000000000001';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  d date := (now() at time zone 'Asia/Dhaka')::date + 2;
  bid uuid;
begin
  perform pg_temp.as_user(u2);
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L,%L,array['lunch']::meal_type[])$q$, s2, d)),
    '2 no exception: booking blocked');
  perform pg_temp.check(pg_temp.fails(format($q$select authorize_exception(%L,%L,'lunch',4000,'self approve')$q$, s2, d)),
    '9 student cannot self-authorize');
  perform pg_temp.as_user(a11);
  perform pg_temp.check(pg_temp.fails(format($q$select authorize_exception(%L,%L,'lunch',4000,'batch admin try')$q$, s2, d)),
    '12 batch admin cannot authorize');

  perform pg_temp.as_user(sa);
  perform authorize_exception(s2, d, 'lunch', 4000, 'hostel fee delayed, approved');
  perform pg_temp.as_user(u2);
  perform book_meals(s2, d, array['lunch']::meal_type[]);
  select id into bid from meal_bookings where student_id = s2 and meal_date = d;
  perform pg_temp.check((select status from meal_bookings where id = bid) = 'authorized_exception',
    '4 authorized booking saved as authorized_exception');
  perform pg_temp.check(pg_temp.fails(format($q$select book_meals(%L,%L,array['lunch','dinner']::meal_type[])$q$, s2, d)),
    'exception amount is a cap (cannot cover extra meal)');

  perform pg_temp.as_user(a11);
  perform confirm_consumption(bid);
  perform pg_temp.check(current_balance(s2) = -4000, '11 authorized meal charged after consumption -> negative balance');
  perform post_transaction(s2, 'deposit', 4000, 'cash', null, 'cleared');
  perform pg_temp.check(current_balance(s2) = 0, 'deposit clears negative balance');
  perform pg_temp.check((select count(*) from audit_logs where action = 'authorize_exception' and target_student = s2) = 1,
    'exception audited');
  raise notice 'ALL 003 TESTS PASSED';
end $$;
rollback;

-- ===================== tests_004.sql =====================
-- Run after 004_pricing_settings.sql and seed_test.sql. Rolls back.
begin;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', name; end if; raise notice 'PASS: %', name; end $$;

do $$
declare
  sa uuid := '00000000-0000-0000-0000-000000000001';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  today date := (now() at time zone 'Asia/Dhaka')::date;
begin
  perform pg_temp.as_user(a11);
  perform pg_temp.check(pg_temp.fails(format($q$select set_meal_price('lunch', 5000, %L)$q$, today + 1)), 'batch admin cannot set price');
  perform pg_temp.check(pg_temp.fails($q$select set_booking_deadline('21:00')$q$), 'batch admin cannot set deadline');

  perform pg_temp.as_user(sa);
  perform pg_temp.check(pg_temp.fails(format($q$select set_meal_price('lunch', 5000, %L)$q$, today - 1)), 'past effective date rejected');
  perform pg_temp.check(pg_temp.fails(format($q$select set_meal_price('lunch', 0, %L)$q$, today + 1)), 'zero price rejected');
  perform set_meal_price('lunch', 5000, today + 5);
  perform pg_temp.check(price_on('lunch', today + 5) = 5000 and price_on('lunch', today + 4) = 4000, 'new price effective from its date only');
  perform pg_temp.check(pg_temp.fails($q$select set_booking_deadline('25:99')$q$), 'bad deadline rejected');
  perform set_booking_deadline('21:30');
  perform pg_temp.check((select value from settings where key = 'booking_deadline') = '21:30', 'deadline updated');
  perform pg_temp.check((select count(*) from audit_logs where action in ('set_meal_price','set_booking_deadline')) = 2, 'changes audited');
  raise notice 'ALL 004 TESTS PASSED';
end $$;
rollback;

-- ===================== tests_005.sql =====================
-- Run after 005_reports.sql, 002 and seed_test.sql. Rolls back.
begin;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', name; end if; raise notice 'PASS: %', name; end $$;

do $$
declare
  s1 uuid := '00000000-0000-0000-0000-0000000000b1';
  u1 uuid := '00000000-0000-0000-0000-0000000000a1';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  today date := (now() at time zone 'Asia/Dhaka')::date;
  d date := (now() at time zone 'Asia/Dhaka')::date + 2;
  bid uuid; r record;
begin
  perform pg_temp.as_user(a11);
  perform post_transaction(s1, 'deposit', 5000, 'bkash', 'REF1', 'x');
  perform post_transaction(s1, 'deposit', 5000, 'bkash', 'REF1', 'x');
  perform pg_temp.check((select count(*) from reconciliation_report() where check_name = 'Possible duplicate deposit') = 1,
    'duplicate deposit flagged');

  perform pg_temp.as_user(u1);
  perform book_meals(s1, d, array['lunch']::meal_type[]);
  select id into bid from meal_bookings where student_id = s1 and meal_date = d;
  perform pg_temp.as_user(a11);
  perform confirm_consumption(bid);

  select * into r from student_ledger_report(today, today + 30, null) where student_id = s1;
  perform pg_temp.check(r.closing = (select sum(delta) from wallet_transactions where student_id = s1),
    '19 report closing balance equals ledger sum');
  perform pg_temp.check(r.opening + r.deposits + r.refunds + r.credit_adj + r.debit_adj + r.meal_charges + r.reversals = r.closing,
    '19 report columns add up to closing');
  perform pg_temp.check(r.meal_charges = -4000 and r.meals_consumed = 1, 'report shows charge and consumption');

  -- inject faults as postgres (bypassing app functions) and check they are detected
  insert into meal_bookings (student_id, meal_date, meal, status, reserved_amount)
    values (s1, today - 3, 'dinner', 'booked', 3500);
  perform pg_temp.check((select count(*) from reconciliation_report() where check_name = 'Unsettled reservation') = 1,
    '20 unsettled reservation flagged');
  raise notice 'ALL 005 TESTS PASSED';
end $$;
rollback;

-- ===================== tests_006.sql =====================
-- Run after 006_management.sql and seed_test.sql. Rolls back.
begin;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.check(c boolean, name text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', name; end if; raise notice 'PASS: %', name; end $$;

do $$
declare
  sa uuid := '00000000-0000-0000-0000-000000000001';
  a11 uuid := '00000000-0000-0000-0000-000000000011';
  s1 uuid := '00000000-0000-0000-0000-0000000000b1';
  b12 int := (select id from batches where name = 'Batch 12');
begin
  perform pg_temp.as_user(a11);
  perform pg_temp.check(pg_temp.fails($q$select upsert_batch(null, 'Hack', true)$q$), 'batch admin cannot create batch');
  perform pg_temp.check(pg_temp.fails(format($q$select set_admin_batches(%L, array[%s])$q$, a11, b12)), 'batch admin cannot change own permissions');
  perform pg_temp.check(pg_temp.fails($q$select set_user_active(auth.uid(), false)$q$), 'cannot deactivate self');

  perform pg_temp.as_user(sa);
  perform upsert_batch(b12, 'Batch 12 (renamed)', true);
  perform pg_temp.check((select name from batches where id = b12) = 'Batch 12 (renamed)', 'super admin renames batch');
  perform set_admin_batches(a11, array[b12]);
  perform pg_temp.as_user(a11);
  perform pg_temp.check(not can_access_student(s1), 'reassigned admin loses access to old batch students');
  perform pg_temp.as_user(sa);
  perform set_student_status(s1, 'suspended');
  perform pg_temp.check((select status from students where id = s1) = 'suspended', 'student suspended');
  perform pg_temp.check((select count(*) from audit_logs where action in ('upsert_batch','set_admin_batches','set_student_status')) = 3, 'management actions audited');
  raise notice 'ALL 006 TESTS PASSED';
end $$;
rollback;
