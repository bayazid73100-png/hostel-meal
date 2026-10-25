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
