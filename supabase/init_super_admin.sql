-- Run ONCE in the Supabase SQL editor, after migrations 001-006 (and NOT seed_test.sql).
-- 1) Supabase dashboard -> Authentication -> Users -> "Add user" (email + strong password, auto-confirm).
-- 2) Put that email below and run this script.
insert into profiles (id, full_name, role)
select id, 'Hostel Super Admin', 'super_admin' from auth.users where email = 'YOUR-ADMIN-EMAIL@example.com'
on conflict (id) do update set role = 'super_admin', is_active = true;

-- Create the six batches (rename later in /admin/people)
insert into batches (name) select 'Batch ' || n from generate_series(11,16) n on conflict (name) do nothing;
