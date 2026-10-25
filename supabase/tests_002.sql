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
