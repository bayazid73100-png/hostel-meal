-- Run after 002. Negative-balance exceptions: Super Admin only, via a server function, always audited.

create function authorize_exception(p_student uuid, p_date date, p_meal meal_type, p_amount int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Only a Super Admin can authorize exceptions'; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if coalesce(length(p_reason),0) < 4 then raise exception 'Reason required'; end if;
  if not exists (select 1 from students where id = p_student and status = 'active') then
    raise exception 'Student not active'; end if;
  insert into authorized_exceptions (student_id, meal_date, meal, amount, authorized_by, reason)
    values (p_student, p_date, p_meal, p_amount, auth.uid(), p_reason) returning authorized_exceptions.id into id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'authorize_exception', p_student,
            jsonb_build_object('exception', id, 'date', p_date, 'meal', p_meal, 'amount', p_amount, 'reason', p_reason));
  return id;
end $$;

-- No direct inserts any more: the function is the only path.
drop policy super_exceptions on authorized_exceptions;
revoke insert, update, delete on authorized_exceptions from anon, authenticated;
revoke execute on function authorize_exception(uuid, date, meal_type, int, text) from anon;
