-- Run after 003. Price and deadline changes go through audited Super-Admin functions only.

create function set_meal_price(p_meal meal_type, p_price int, p_from date) returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone (select value from settings where key = 'timezone'))::date;
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_price <= 0 then raise exception 'Price must be positive'; end if;
  if p_from < today then raise exception 'Effective date cannot be in the past'; end if;
  if exists (select 1 from meal_prices where meal = p_meal and effective_from = p_from and effective_from <= today) then
    raise exception 'A price already took effect on that date; choose a later date'; end if;
  insert into meal_prices (meal, price, effective_from, created_by) values (p_meal, p_price, p_from, auth.uid())
    on conflict (meal, effective_from) do update set price = excluded.price, created_by = auth.uid();
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_meal_price', jsonb_build_object('meal', p_meal, 'price', p_price, 'from', p_from));
end $$;

create function set_booking_deadline(p_time text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is distinct from 'super_admin' then raise exception 'Super Admin only'; end if;
  if p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Use 24-hour HH:MM'; end if;
  update settings set value = p_time where key = 'booking_deadline';
  insert into audit_logs (actor, action, details)
    values (auth.uid(), 'set_booking_deadline', jsonb_build_object('time', p_time));
end $$;

drop policy super_prices on meal_prices;
drop policy super_settings on settings;
revoke insert, update, delete on meal_prices, settings from anon, authenticated;
revoke execute on function set_meal_price(meal_type, int, date), set_booking_deadline(text) from anon;
