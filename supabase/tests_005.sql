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
