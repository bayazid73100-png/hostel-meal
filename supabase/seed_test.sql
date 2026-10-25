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
