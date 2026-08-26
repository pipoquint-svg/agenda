-- I-09 / Adendo 1+2: active services must own an explicit change policy.
-- Expand-only schema hardening plus deterministic deactivation of two known sandbox fixtures.
-- No commercial policy value is inferred or backfilled.

-- Deterministic fixture treatment: both rows were inventoried as non-commercial test fixtures.
update public.services s
set is_active = false,
    updated_at = now()
where s.is_active = true
  and s.name in ('[TESTE] Locação BlackSheep Kommo', 'Token Evidence Service')
  and not exists (
    select 1 from public.service_change_policies p where p.service_id = s.id
  );

-- Application-facing creation APIs create a draft. Activation remains an explicit later action
-- and is guarded by the deferred invariant below. Signatures/contracts are unchanged.
create or replace function public.service_admin_create_service_audited(
  p_name text,
  p_slug text,
  p_operation_scope text,
  p_short_description text,
  p_full_description text,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_base_price numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_mode text := upper(btrim(coalesce(p_duration_mode,'FIXED')));
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='SERVICE_OPERATION_SCOPE_INVALID'; end if;
  if v_mode not in ('FIXED','BLOCKS') then raise exception using errcode='P0001', message='INVALID_DURATION_MODE'; end if;
  if coalesce(p_base_duration_minutes,0) <= 0 then raise exception using errcode='P0001', message='INVALID_BASE_DURATION'; end if;
  if coalesce(p_base_price,-1) < 0 then raise exception using errcode='P0001', message='INVALID_BASE_PRICE'; end if;
  if coalesce(p_buffer_before_minutes,-1) < 0 or coalesce(p_buffer_after_minutes,-1) < 0 then raise exception using errcode='P0001', message='INVALID_BUFFER'; end if;

  insert into public.services(
    category_id,name,slug,short_description,full_description,base_duration_minutes,
    buffer_before_minutes,buffer_after_minutes,base_price,is_active,sort_order,
    duration_mode,operation_scope
  ) values (
    null,btrim(p_name),btrim(p_slug),nullif(btrim(p_short_description),''),nullif(btrim(p_full_description),''),
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,false,
    coalesce((select max(sort_order)+10 from public.services where operation_scope=v_scope),0),
    v_mode,v_scope
  ) returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,public.service_admin_service_snapshot(v_id),'ADMIN');
  return public.service_admin_service_snapshot(v_id);
end;
$$;

create or replace function public.service_admin_create_service_catalog_audited(
  p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_short_description text, p_full_description text,
  p_duration_mode text, p_base_duration_minutes integer, p_base_price numeric,
  p_buffer_before_minutes integer, p_buffer_after_minutes integer,
  p_minimum_people integer, p_maximum_people integer, p_price_per_extra_person numeric,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_mode text := upper(btrim(coalesce(p_duration_mode,'FIXED')));
  v_category_scope text;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select operation_scope into v_category_scope from public.categories where id=p_category_id and is_active;
  if not found then raise exception using errcode='P0001', message='CATEGORY_NOT_AVAILABLE'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') or v_category_scope<>v_scope then raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if v_mode not in ('FIXED','BLOCKS') then raise exception using errcode='P0001', message='INVALID_DURATION_MODE'; end if;
  if coalesce(p_base_duration_minutes,0)<=0 then raise exception using errcode='P0001', message='INVALID_BASE_DURATION'; end if;
  if coalesce(p_base_price,-1)<0 or coalesce(p_price_per_extra_person,-1)<0 then raise exception using errcode='P0001', message='INVALID_PRICE'; end if;
  if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001', message='INVALID_PEOPLE_RANGE'; end if;
  if coalesce(p_buffer_before_minutes,-1)<0 or coalesce(p_buffer_after_minutes,-1)<0 then raise exception using errcode='P0001', message='INVALID_BUFFER'; end if;

  insert into public.services(category_id,name,slug,short_description,full_description,base_duration_minutes,
    buffer_before_minutes,buffer_after_minutes,base_price,minimum_people,maximum_people,price_per_extra_person,
    is_active,sort_order,duration_mode,operation_scope)
  values(p_category_id,btrim(p_name),btrim(p_slug),nullif(btrim(p_short_description),''),nullif(btrim(p_full_description),''),
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,p_minimum_people,p_maximum_people,
    p_price_per_extra_person,false,coalesce((select max(sort_order)+10 from public.services where category_id=p_category_id),0),v_mode,v_scope)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,(select to_jsonb(s) from public.services s where s.id=v_id),'ADMIN');
  return (select to_jsonb(s) from public.services s where s.id=v_id);
end;
$$;

-- Deferred source-side invariant. It permits service + policy to be created in one transaction,
-- while rejecting commit if the resulting active service has no policy. Reactivation is covered.
create or replace function public.enforce_active_service_has_change_policy()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.services s
    where s.id = new.id
      and s.is_active = true
      and not exists (
        select 1 from public.service_change_policies p where p.service_id = s.id
      )
  ) then
    raise exception using errcode='23514', message='ACTIVE_SERVICE_CHANGE_POLICY_REQUIRED';
  end if;
  return null;
end;
$$;

drop trigger if exists services_active_change_policy_guard on public.services;
create constraint trigger services_active_change_policy_guard
after insert or update of is_active on public.services
deferrable initially deferred
for each row execute function public.enforce_active_service_has_change_policy();

-- Opposite direction: an active service cannot lose its policy. Deferred so a transaction may
-- deactivate the service and delete its policy atomically.
create or replace function public.prevent_active_service_policy_removal()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1 from public.services s
    where s.id = old.service_id and s.is_active = true
  ) and not exists (
    select 1 from public.service_change_policies p where p.service_id = old.service_id
  ) then
    raise exception using errcode='23514', message='ACTIVE_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED';
  end if;
  return null;
end;
$$;

drop trigger if exists active_service_policy_delete_guard on public.service_change_policies;
create constraint trigger active_service_policy_delete_guard
after delete on public.service_change_policies
deferrable initially deferred
for each row execute function public.prevent_active_service_policy_removal();

-- Fail loudly at capture point. With the source invariant above this is a last-resort safety net,
-- not normal application control flow.
create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id=new.id
  ) then return new; end if;

  select * into v_policy
  from public.service_change_policies
  where service_id=new.service_id;
  if not found then
    raise exception using errcode='P0001',
      message='APPOINTMENT_CHANGE_POLICY_MISSING_FOR_SERVICE',
      detail='service_id=' || new.service_id::text;
  end if;

  select coalesce(s.max_reschedules,3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if v_max_reschedules is null then
    raise exception using errcode='P0001',message='SERVICE_RESCHEDULE_CONFIGURATION_MISSING';
  end if;

  v_effective_at := case
    when new.status='AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at,new.created_at)
  end;

  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;
