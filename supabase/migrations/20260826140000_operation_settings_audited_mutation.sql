-- Issue #218 phase 2: audited per-operation settings mutation.
-- Keep legacy operation_settings untouched. This RPC updates only scoped overrides,
-- enforces existing admin permissions, and records before/after resolved settings.

alter table public.operation_setting_overrides
  add column if not exists id uuid not null default gen_random_uuid();

create unique index if not exists operation_setting_overrides_id_key
  on public.operation_setting_overrides(id);

create or replace function public.service_admin_update_operation_settings_v2(
  p_operation_scope text,
  p_patch jsonb,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_existing public.operation_setting_overrides%rowtype;
  v_row public.operation_setting_overrides%rowtype;
  v_entity_id uuid;
  v_allowed_keys constant text[] := array[
    'public_name','public_email','public_phone','public_address','public_site_url',
    'timezone','default_currency','checkout_hold_minutes','payment_hold_minutes',
    'agency_hold_minutes','default_confirmation_percentage','pix_discount_percent',
    'default_slot_interval_minutes'
  ];
begin
  if p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception using errcode='P0001', message='OPERATION_SCOPE_INVALID';
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_PATCH_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(p_patch) as k(key)
    where not (k.key = any(v_allowed_keys))
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_PATCH_KEY_INVALID';
  end if;

  if not public.service_admin_has_permission(p_actor_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  if p_patch ? 'pix_discount_percent'
     and not public.service_admin_has_permission(p_actor_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_FINANCE_PERMISSION_REQUIRED';
  end if;

  if exists (
    select 1
    from jsonb_each(p_patch) as e(key,value)
    where e.key = any(array['public_name','public_email','public_phone','public_address','public_site_url','timezone','default_currency'])
      and jsonb_typeof(e.value) not in ('string','null')
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_TEXT_VALUE_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_each(p_patch) as e(key,value)
    where e.key = any(array['checkout_hold_minutes','payment_hold_minutes','agency_hold_minutes','default_confirmation_percentage','pix_discount_percent','default_slot_interval_minutes'])
      and jsonb_typeof(e.value) not in ('number','null')
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_NUMERIC_VALUE_INVALID';
  end if;

  v_before := public.service_admin_get_operation_settings_v2(p_operation_scope);
  select * into v_existing
  from public.operation_setting_overrides
  where operation_scope=p_operation_scope
  for update;

  insert into public.operation_setting_overrides(
    operation_scope,
    public_name,public_email,public_phone,public_address,public_site_url,
    timezone,default_currency,checkout_hold_minutes,payment_hold_minutes,
    agency_hold_minutes,default_confirmation_percentage,pix_discount_percent,
    default_slot_interval_minutes,updated_at
  ) values (
    p_operation_scope,
    case when p_patch ? 'public_name' then p_patch->>'public_name' else v_existing.public_name end,
    case when p_patch ? 'public_email' then p_patch->>'public_email' else v_existing.public_email end,
    case when p_patch ? 'public_phone' then p_patch->>'public_phone' else v_existing.public_phone end,
    case when p_patch ? 'public_address' then p_patch->>'public_address' else v_existing.public_address end,
    case when p_patch ? 'public_site_url' then p_patch->>'public_site_url' else v_existing.public_site_url end,
    case when p_patch ? 'timezone' then p_patch->>'timezone' else v_existing.timezone end,
    case when p_patch ? 'default_currency' then p_patch->>'default_currency' else v_existing.default_currency end,
    case when p_patch ? 'checkout_hold_minutes' then (p_patch->>'checkout_hold_minutes')::integer else v_existing.checkout_hold_minutes end,
    case when p_patch ? 'payment_hold_minutes' then (p_patch->>'payment_hold_minutes')::integer else v_existing.payment_hold_minutes end,
    case when p_patch ? 'agency_hold_minutes' then (p_patch->>'agency_hold_minutes')::integer else v_existing.agency_hold_minutes end,
    case when p_patch ? 'default_confirmation_percentage' then (p_patch->>'default_confirmation_percentage')::numeric else v_existing.default_confirmation_percentage end,
    case when p_patch ? 'pix_discount_percent' then (p_patch->>'pix_discount_percent')::numeric else v_existing.pix_discount_percent end,
    case when p_patch ? 'default_slot_interval_minutes' then (p_patch->>'default_slot_interval_minutes')::integer else v_existing.default_slot_interval_minutes end,
    now()
  )
  on conflict(operation_scope) do update set
    public_name=excluded.public_name,
    public_email=excluded.public_email,
    public_phone=excluded.public_phone,
    public_address=excluded.public_address,
    public_site_url=excluded.public_site_url,
    timezone=excluded.timezone,
    default_currency=excluded.default_currency,
    checkout_hold_minutes=excluded.checkout_hold_minutes,
    payment_hold_minutes=excluded.payment_hold_minutes,
    agency_hold_minutes=excluded.agency_hold_minutes,
    default_confirmation_percentage=excluded.default_confirmation_percentage,
    pix_discount_percent=excluded.pix_discount_percent,
    default_slot_interval_minutes=excluded.default_slot_interval_minutes,
    updated_at=now()
  returning * into v_row;

  v_entity_id := v_row.id;

  if v_row.public_name is null
     and v_row.public_email is null
     and v_row.public_phone is null
     and v_row.public_address is null
     and v_row.public_site_url is null
     and v_row.timezone is null
     and v_row.default_currency is null
     and v_row.checkout_hold_minutes is null
     and v_row.payment_hold_minutes is null
     and v_row.agency_hold_minutes is null
     and v_row.default_confirmation_percentage is null
     and v_row.pix_discount_percent is null
     and v_row.default_slot_interval_minutes is null then
    delete from public.operation_setting_overrides where operation_scope=p_operation_scope;
  end if;

  v_after := public.service_admin_get_operation_settings_v2(p_operation_scope);

  if v_before is distinct from v_after then
    insert into public.audit_logs(
      admin_user_id,entity_type,entity_id,action,before_json,after_json,origin
    ) values (
      p_actor_admin_id,'OPERATION_SETTINGS',v_entity_id,'OPERATION_SETTINGS_CHANGED',
      v_before,v_after,'ADMIN'
    );
  end if;

  return v_after;
end;
$$;

revoke all on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid)
  to service_role;

comment on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid) is
  'Audited scoped settings mutation. Requires SERVICES_MANAGE; PIX discount additionally requires FINANCE_MANAGE. Null resets a field to global inheritance.';
