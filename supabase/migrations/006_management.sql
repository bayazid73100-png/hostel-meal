-- Run after 005. Audited Super-Admin management functions. Account creation is done by the server-only API route.

create function upsert_batch(p_id int, p_name text, p_active boolean) returns int
language plpgsql security definer set search_path = public as $$
declare rid int;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if coalesce(length(trim(p_name)),0) < 2 then raise exception 'Batch name required'; end if;
  if p_id is null then
    insert into batches (name, is_active) values (trim(p_name), coalesce(p_active, true)) returning id into rid;
  else
    update batches set name = trim(p_name), is_active = coalesce(p_active, is_active) where id = p_id returning id into rid;
    if rid is null then raise exception 'Batch not found'; end if;
  end if;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'upsert_batch', jsonb_build_object('batch', rid, 'name', p_name, 'active', p_active));
  return rid;
end $$;

create function set_student_status(p_student uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_status not in ('active','suspended','inactive') then raise exception 'Invalid status'; end if;
  update students set status = p_status where id = p_student;
  if not found then raise exception 'Student not found'; end if;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'set_student_status', p_student, jsonb_build_object('status', p_status));
end $$;

create function set_admin_batches(p_admin uuid, p_batches int[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if not exists (select 1 from profiles where id = p_admin and role = 'batch_admin') then
    raise exception 'Target is not a batch admin'; end if;
  delete from admin_batches where admin_id = p_admin;
  insert into admin_batches (admin_id, batch_id) select p_admin, b from unnest(p_batches) b;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_admin_batches', jsonb_build_object('admin', p_admin, 'batches', p_batches));
end $$;

create function set_user_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own account status'; end if;
  update profiles set is_active = p_active where id = p_user;
  if not found then raise exception 'User not found'; end if;
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_user_active', jsonb_build_object('user', p_user, 'active', p_active));
end $$;

-- All writes now go through the functions above (or the service-role API route).
drop policy super_batches on batches;
drop policy super_students on students;
drop policy super_assign on admin_batches;
drop policy super_profiles on profiles;
revoke insert, update, delete on batches, students, admin_batches, profiles from anon, authenticated;
revoke execute on function upsert_batch(int, text, boolean), set_student_status(uuid, text),
  set_admin_batches(uuid, int[]), set_user_active(uuid, boolean) from anon;
