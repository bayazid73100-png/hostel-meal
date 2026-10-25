-- Run after 001_core_schema.sql. Adds missed-meal marking and re-confirmable reversals.

-- 1) Consumption rows: allow ONLY setting reversed_at (null -> timestamp); uniqueness applies to unreversed rows.
alter table meal_consumptions add column reversed_at timestamptz;
alter table meal_consumptions drop constraint meal_consumptions_booking_id_key;
alter table meal_consumptions drop constraint meal_consumptions_student_id_meal_date_meal_key;
create unique index one_live_consumption_per_booking on meal_consumptions(booking_id) where reversed_at is null;
create unique index one_live_consumption_per_meal on meal_consumptions(student_id, meal_date, meal) where reversed_at is null;

create or replace function guard_consumption() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.reversed_at is null and new.reversed_at is not null
     and (new.id, new.booking_id, new.student_id, new.meal_date, new.meal, new.price, new.confirmed_by, new.confirmed_at)
         is not distinct from
         (old.id, old.booking_id, old.student_id, old.meal_date, old.meal, old.price, old.confirmed_by, old.confirmed_at)
  then return new; end if;
  raise exception 'Immutable table: only reversal marking is allowed';
end $$;
drop trigger consumption_immutable on meal_consumptions;
create trigger consumption_guard before update or delete on meal_consumptions
  for each row execute function guard_consumption();

-- 2) One charge per consumption (not per booking), so a reversed meal can be re-confirmed.
alter table wallet_transactions add column consumption_id uuid references meal_consumptions(id);
drop index one_charge_per_booking;
create unique index one_charge_per_consumption on wallet_transactions(consumption_id) where type = 'meal_charge';

create or replace function confirm_consumption(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b meal_bookings; pr int; cid uuid;
begin
  select * into b from meal_bookings where id = p_booking for update;
  if not found or not is_admin_for(b.student_id) then raise exception 'Not allowed'; end if;
  if b.status not in ('booked','authorized_exception') then raise exception 'Booking not confirmable (%).', b.status; end if;
  perform 1 from students where id = b.student_id for update;
  pr := price_on(b.meal, b.meal_date);
  insert into meal_consumptions (booking_id, student_id, meal_date, meal, price, confirmed_by)
    values (b.id, b.student_id, b.meal_date, b.meal, pr, auth.uid()) returning id into cid;
  insert into wallet_transactions (student_id, type, delta, booking_id, consumption_id, exception_id, created_by)
    values (b.student_id, 'meal_charge', -pr, b.id, cid, b.exception_id, auth.uid());
  update meal_bookings set status = 'consumed', reserved_amount = 0, updated_at = now() where id = b.id;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'confirm_consumption', b.student_id, jsonb_build_object('booking', b.id, 'price', pr));
end $$;

create or replace function reverse_transaction(p_txn uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t wallet_transactions; id uuid;
begin
  select * into t from wallet_transactions where id = p_txn;
  if not found or not is_admin_for(t.student_id) then raise exception 'Not allowed'; end if;
  if t.type = 'reversal' then raise exception 'Cannot reverse a reversal'; end if;
  if coalesce(length(p_reason),0) < 4 then raise exception 'Reason required'; end if;
  perform 1 from students where id = t.student_id for update;
  insert into wallet_transactions (student_id, type, delta, reverses_id, created_by, note)
    values (t.student_id, 'reversal', -t.delta, t.id, auth.uid(), p_reason) returning wallet_transactions.id into id;
  if t.type = 'meal_charge' then
    update meal_consumptions set reversed_at = now() where id = t.consumption_id;
    update meal_bookings set status = 'booked', reserved_amount = price_on(meal, meal_date), updated_at = now()
      where id = t.booking_id;
  end if;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'reverse', t.student_id, jsonb_build_object('txn', t.id, 'reason', p_reason));
  return id;
end $$;

-- 3) Reverse the live charge of a consumed booking (used by the admin UI)
create function reverse_meal_charge(p_booking uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid; sid uuid;
begin
  select student_id into sid from meal_bookings where id = p_booking;
  if sid is null or not is_admin_for(sid) then raise exception 'Not allowed'; end if;
  select w.id into t from wallet_transactions w
    join meal_consumptions c on c.id = w.consumption_id
   where w.booking_id = p_booking and w.type = 'meal_charge' and c.reversed_at is null;
  if t is null then raise exception 'No live charge for this booking'; end if;
  return reverse_transaction(t, p_reason);
end $$;

-- 4) Missed meal: never charged
create function mark_missed(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b meal_bookings;
begin
  select * into b from meal_bookings where id = p_booking for update;
  if not found or not is_admin_for(b.student_id) then raise exception 'Not allowed'; end if;
  if b.status not in ('booked','authorized_exception') then raise exception 'Cannot mark missed (%).', b.status; end if;
  update meal_bookings set status = 'missed', reserved_amount = 0, updated_at = now() where id = p_booking;
  insert into audit_logs (actor, action, target_student, details)
    values (auth.uid(), 'mark_missed', b.student_id, jsonb_build_object('booking', b.id));
end $$;

revoke execute on function mark_missed(uuid), reverse_meal_charge(uuid, text) from anon;
