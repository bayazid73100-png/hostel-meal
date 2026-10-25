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
