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
