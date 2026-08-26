-- Issue #217 — administrative management for birthday automation settings.
-- This remains configuration-only: no scheduler, coupon generation, notification enqueue or provider call is introduced.

create or replace function public.service_admin_list_birthday_automation_settings()
returns table (
  id uuid,
  operation_scope text,
  is_active boolean,
  send_message boolean,
  generate_coupon boolean,
  send_on_birthday boolean,
  days_before integer,
  coupon_prefix text,
  coupon_discount_type text,
  coupon_discount_value numeric,
  coupon_validity_days integer,
  coupon_max_uses integer,
  coupon_max_uses_per_customer integer,
  updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    s.id,
    s.operation_scope,
    s.is_active,
    s.send_message,
    s.generate_coupon,
    s.send_on_birthday,
    s.days_before,
    s.coupon_prefix,
    s.coupon_discount_type,
    s.coupon_discount_value,
    s.coupon_validity_days,
    s.coupon_max_uses,
    s.coupon_max_uses_per_customer,
    s.updated_at
  from public.birthday_automation_settings s
  order by s.operation_scope;
$$;

create or replace function public.service_admin_update_birthday_automation_settings(
  p_operation_scope text,
  p_is_active boolean,
  p_send_message boolean,
  p_generate_coupon boolean,
  p_send_on_birthday boolean,
  p_days_before integer,
  p_coupon_prefix text,
  p_coupon_discount_type text,
  p_coupon_discount_value numeric,
  p_coupon_validity_days integer,
  p_coupon_max_uses integer,
  p_coupon_max_uses_per_customer integer,
  p_actor_admin_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.birthday_automation_settings%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_financial_change boolean;
begin
  if p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception 'BIRTHDAY_OPERATION_SCOPE_INVALID';
  end if;
  if p_actor_admin_id is null then
    raise exception 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_actor_admin_id, 'SERVICES_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_row
  from public.birthday_automation_settings
  where operation_scope = p_operation_scope
  for update;
  if not found then raise exception 'BIRTHDAY_SETTINGS_NOT_FOUND'; end if;

  v_before := to_jsonb(v_row);
  v_financial_change :=
       v_row.generate_coupon is distinct from coalesce(p_generate_coupon, false)
    or v_row.coupon_prefix is distinct from nullif(btrim(p_coupon_prefix), '')
    or v_row.coupon_discount_type is distinct from nullif(upper(btrim(p_coupon_discount_type)), '')
    or v_row.coupon_discount_value is distinct from p_coupon_discount_value
    or v_row.coupon_validity_days is distinct from p_coupon_validity_days
    or v_row.coupon_max_uses is distinct from p_coupon_max_uses
    or v_row.coupon_max_uses_per_customer is distinct from p_coupon_max_uses_per_customer;

  if v_financial_change and not public.service_admin_has_permission(p_actor_admin_id, 'FINANCE_MANAGE') then
    raise exception 'ADMIN_FINANCE_PERMISSION_REQUIRED';
  end if;

  update public.birthday_automation_settings
  set is_active = coalesce(p_is_active, false),
      send_message = coalesce(p_send_message, false),
      generate_coupon = coalesce(p_generate_coupon, false),
      send_on_birthday = coalesce(p_send_on_birthday, false),
      days_before = p_days_before,
      coupon_prefix = nullif(btrim(p_coupon_prefix), ''),
      coupon_discount_type = nullif(upper(btrim(p_coupon_discount_type)), ''),
      coupon_discount_value = p_coupon_discount_value,
      coupon_validity_days = p_coupon_validity_days,
      coupon_max_uses = p_coupon_max_uses,
      coupon_max_uses_per_customer = p_coupon_max_uses_per_customer,
      updated_at = now()
  where operation_scope = p_operation_scope
  returning to_jsonb(birthday_automation_settings.*) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_actor_admin_id,
    'BIRTHDAY_AUTOMATION_SETTINGS',
    v_row.id,
    'UPDATE',
    v_before,
    v_after,
    'ADMIN'
  );

  return v_row.id;
end;
$$;

revoke all on function public.service_admin_list_birthday_automation_settings() from public, anon, authenticated;
revoke all on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_birthday_automation_settings() to service_role;
grant execute on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) to service_role;

comment on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) is
  'Audited administrative settings mutation only. It does not execute birthday cycles, generate coupons or enqueue notifications.';
