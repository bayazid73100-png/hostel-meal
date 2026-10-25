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
