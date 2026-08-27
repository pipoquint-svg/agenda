-- Issue #217 — canonical customer birth date management.
-- Adds a narrow, audited mutation for person customers only. No historical appointment snapshots are rewritten.

create or replace function public.service_admin_set_customer_birth_date(
  p_customer_id uuid,
  p_birth_date date,
  p_admin_id uuid
)
returns date
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer_type text;
  v_before date;
  v_after date;
begin
  if p_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_admin_id, 'CUSTOMERS_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select customer_type, birth_date
    into v_customer_type, v_before
  from public.customers
  where id = p_customer_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;
  if upper(coalesce(v_customer_type, '')) not in ('PERSON','PESSOA','INDIVIDUAL') then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_BIRTH_DATE_PERSON_ONLY';
  end if;
  if p_birth_date is not null and p_birth_date > current_date then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_BIRTH_DATE_FUTURE';
  end if;

  update public.customers
  set birth_date = p_birth_date,
      updated_at = now()
  where id = p_customer_id
  returning birth_date into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_admin_id,
    'CUSTOMER',
    p_customer_id,
    'BIRTH_DATE_CHANGED',
    jsonb_build_object('birth_date', v_before),
    jsonb_build_object('birth_date', v_after),
    'ADMIN'
  );

  return v_after;
end;
$$;

revoke all on function public.service_admin_set_customer_birth_date(uuid,date,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_customer_birth_date(uuid,date,uuid) to service_role;

comment on function public.service_admin_set_customer_birth_date(uuid,date,uuid) is
  'Audited canonical birth date mutation for person customers. Does not rewrite historical appointment snapshots or trigger birthday automation.';
