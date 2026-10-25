-- Run after 004. Reports and reconciliation. SECURITY INVOKER: RLS applies, so batch admins only see their batches.

-- Fix: admins must be able to read the names of students they can access.
create policy read_student_profiles on profiles for select
  using (exists (select 1 from students s where s.user_id = profiles.id and can_access_student(s.id)));

create function student_ledger_report(p_from date, p_to date, p_batch int default null)
returns table (student_id uuid, student_code text, full_name text, batch text,
  opening bigint, deposits bigint, refunds bigint, credit_adj bigint, debit_adj bigint,
  meal_charges bigint, reversals bigint, closing bigint, meals_booked int, meals_consumed int)
language sql stable as $$
  select s.id, s.student_code, p.full_name, b.name,
    coalesce(sum(t.delta) filter (where t.d < p_from), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'deposit'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'refund'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'credit_adj'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'debit_adj'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'meal_charge'), 0),
    coalesce(sum(t.delta) filter (where t.d between p_from and p_to and t.type = 'reversal'), 0),
    coalesce(sum(t.delta) filter (where t.d <= p_to), 0),
    (select count(*) from meal_bookings mb where mb.student_id = s.id and mb.meal_date between p_from and p_to
       and mb.status <> 'cancelled')::int,
    (select count(*) from meal_consumptions c where c.student_id = s.id and c.meal_date between p_from and p_to
       and c.reversed_at is null)::int
  from students s
  join batches b on b.id = s.batch_id
  left join profiles p on p.id = s.user_id
  left join lateral (select w.type, w.delta, (w.created_at at time zone 'Asia/Dhaka')::date as d
                     from wallet_transactions w where w.student_id = s.id) t on true
  where p_batch is null or s.batch_id = p_batch
  group by s.id, s.student_code, p.full_name, b.name
  order by b.name, s.student_code $$;

-- Note: opening balances are ledger rows of type 'opening' (counted in "opening" if dated before the range).

create function reconciliation_report()
returns table (check_name text, student_code text, detail text)
language sql stable as $$
  select 'Consumption without live charge', s.student_code, c.meal_date || ' ' || c.meal
    from meal_consumptions c join students s on s.id = c.student_id
   where c.reversed_at is null
     and not exists (select 1 from wallet_transactions w where w.consumption_id = c.id and w.type = 'meal_charge')
  union all
  select 'Charge without valid consumption', s.student_code, w.created_at::date || ' ' || w.delta
    from wallet_transactions w join students s on s.id = w.student_id
    left join meal_consumptions c on c.id = w.consumption_id
   where w.type = 'meal_charge'
     and not exists (select 1 from wallet_transactions r where r.reverses_id = w.id)
     and (c.id is null or c.reversed_at is not null)
  union all
  select 'Possible duplicate deposit', s.student_code, d.method || ' / ' || d.reference || ' x' || d.n
    from (select w.student_id, w.method, w.reference, count(*) n from wallet_transactions w
           where w.type = 'deposit' and w.reference is not null
             and not exists (select 1 from wallet_transactions r where r.reverses_id = w.id)
           group by 1, 2, 3 having count(*) > 1) d
    join students s on s.id = d.student_id
  union all
  select 'Unsettled reservation', s.student_code, mb.meal_date || ' ' || mb.meal
    from meal_bookings mb join students s on s.id = mb.student_id
   where mb.reserved_amount > 0 and mb.status in ('booked', 'authorized_exception')
     and mb.meal_date < (now() at time zone 'Asia/Dhaka')::date
  union all
  select 'Negative balance without any exception', s.student_code, current_balance(s.id)::text
    from students s
   where current_balance(s.id) < 0
     and not exists (select 1 from authorized_exceptions e where e.student_id = s.id)
  union all
  select 'Multiple opening balances', s.student_code, count(*)::text
    from wallet_transactions w join students s on s.id = w.student_id
   where w.type = 'opening' group by s.student_code having count(*) > 1
  union all
  select 'Adjustment without admin author', s.student_code, w.type || ' ' || w.delta
    from wallet_transactions w join students s on s.id = w.student_id
   where w.type in ('credit_adj', 'debit_adj')
     and (w.created_by is null or not exists (select 1 from profiles p where p.id = w.created_by
          and p.role in ('super_admin', 'batch_admin'))) $$;

revoke execute on function student_ledger_report(date, date, int), reconciliation_report() from anon;
