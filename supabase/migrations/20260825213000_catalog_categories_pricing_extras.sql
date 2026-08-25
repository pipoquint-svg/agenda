-- Complete the administrative catalog: operation -> category -> service.
-- Categories remain first-class. Services expose people pricing, day/time rules and extras.

alter table public.categories
  add column if not exists operation_scope text;

alter table public.categories drop constraint if exists categories_operation_scope_check;
alter table public.categories add constraint categories_operation_scope_check
  check (operation_scope is null or operation_scope in ('SABRINA','BLACKSHEEP'));

alter table public.services
  add column if not exists price_per_extra_person numeric(12,2) not null default 0;

alter table public.services drop constraint if exists services_price_per_extra_person_check;
alter table public.services add constraint services_price_per_extra_person_check
  check (price_per_extra_person >= 0);

-- Safe backfill only when every classified service inside a category agrees on one operation.
update public.categories c
set operation_scope = x.operation_scope,
    updated_at = now()
from (
  select category_id, min(operation_scope) as operation_scope
  from public.services
  where category_id is not null and operation_scope is not null
  group by category_id
  having count(distinct operation_scope) = 1
) x
where c.id = x.category_id
  and c.operation_scope is null;

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;
  if v_category_scope is null then
    raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_REQUIRED';
  end if;
  if new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;
  return new;
end;
$$;

drop trigger if exists services_category_operation_guard on public.services;
create trigger services_category_operation_guard
before insert or update of category_id, operation_scope on public.services
for each row execute function public.enforce_service_category_operation();

create or replace function public.enforce_category_operation_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.operation_scope is distinct from new.operation_scope
     and exists (
       select 1 from public.services s
       where s.category_id = new.id
         and s.operation_scope is distinct from new.operation_scope
     ) then
    raise exception using errcode='P0001', message='CATEGORY_OPERATION_HAS_CONFLICTING_SERVICES';
  end if;
  return new;
end;
$$;

drop trigger if exists categories_operation_guard on public.categories;
create trigger categories_operation_guard
before update of operation_scope on public.categories
for each row execute function public.enforce_category_operation_change();

create or replace function public.service_admin_list_categories()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'slug', c.slug,
    'operation_scope', c.operation_scope,
    'sort_order', c.sort_order,
    'is_active', c.is_active,
    'service_count', (select count(*) from public.services s where s.category_id=c.id)
  ) order by case c.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end, c.sort_order, c.name), '[]'::jsonb)
  from public.categories c;
$$;

create or replace function public.service_admin_list_extras()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'name', e.name,
    'description', e.description,
    'price', e.price,
    'duration_delta_minutes', e.duration_delta_minutes,
    'is_active', e.is_active,
    'service_count', (select count(*) from public.service_extras se where se.extra_id=e.id)
  ) order by e.name, e.id), '[]'::jsonb)
  from public.extras e;
$$;

create or replace function public.service_admin_list_service_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', s.id,
  'name', s.name,
  'slug', s.slug,
  'short_description', s.short_description,
  'full_description', s.full_description,
  'category_id', s.category_id,
  'category_name', c.name,
  'operation_scope', s.operation_scope,
  'is_active', s.is_active,
  'sort_order', s.sort_order,
  'duration_mode', s.duration_mode,
  'base_duration_minutes', s.base_duration_minutes,
  'booking_block_minutes', s.booking_block_minutes,
  'minimum_booking_blocks', s.minimum_booking_blocks,
  'maximum_booking_blocks', s.maximum_booking_blocks,
  'price_per_block', s.price_per_block,
  'base_price', s.base_price,
  'minimum_people', s.minimum_people,
  'maximum_people', s.maximum_people,
  'price_per_extra_person', s.price_per_extra_person,
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'custom_fields', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id, 'field_key', f.field_key, 'label', f.label, 'field_type', f.field_type,
      'help_text', f.help_text, 'placeholder', f.placeholder, 'is_required', f.is_required,
      'sort_order', f.sort_order, 'options_json', f.options_json, 'is_active', f.is_active
    ) order by f.sort_order, f.label, f.id)
    from public.service_fields f where f.service_id=s.id
  ), '[]'::jsonb),
  'day_time_pricing_rules', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'name', pr.name, 'days_of_week', pr.days_of_week,
      'start_local_time', pr.start_local_time, 'end_local_time', pr.end_local_time,
      'valid_from_date', pr.valid_from_date, 'valid_until_date', pr.valid_until_date,
      'action_type', pr.action_type, 'amount', pr.amount, 'percentage', pr.percentage,
      'priority', pr.priority, 'is_active', pr.is_active
    ) order by pr.priority, pr.id)
    from public.pricing_rules pr
    where pr.service_id=s.id and pr.rule_scope='DAY_TIME'
  ), '[]'::jsonb),
  'service_extras', coalesce((
    select jsonb_agg(jsonb_build_object(
      'extra_id', e.id, 'name', e.name, 'description', e.description, 'price', e.price,
      'duration_delta_minutes', e.duration_delta_minutes, 'is_active', e.is_active,
      'sort_order', se.sort_order, 'is_required', se.is_required, 'max_quantity', se.max_quantity,
      'schedule_placement', se.schedule_placement,
      'default_schedule_minutes', coalesce(se.default_schedule_minutes, e.duration_delta_minutes)
    ) order by se.sort_order, e.name, e.id)
    from public.service_extras se join public.extras e on e.id=se.extra_id
    where se.service_id=s.id
  ), '[]'::jsonb),
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'min_blocks', t.min_blocks, 'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block, 'is_active', t.is_active, 'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t where t.service_id=s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'block_count', p.block_count, 'title', p.title, 'description', p.description,
      'badge', p.badge, 'is_featured', p.is_featured, 'is_active', p.is_active, 'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p where p.service_id=s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp)-'service_id'-'created_at'-'updated_at'
    from public.service_change_policies cp where cp.service_id=s.id
  )
) order by case s.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end,
           coalesce(c.sort_order, 2147483647), s.sort_order, s.name), '[]'::jsonb)
from public.services s
left join public.categories c on c.id=s.category_id;
$$;

create or replace function public.service_admin_create_category_audited(
  p_name text, p_slug text, p_operation_scope text, p_admin_id uuid
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
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='CATEGORY_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='CATEGORY_SLUG_INVALID'; end if;

  insert into public.categories(name,slug,operation_scope,sort_order,is_active)
  values(btrim(p_name),btrim(p_slug),v_scope,
    coalesce((select max(sort_order)+10 from public.categories where operation_scope=v_scope),0),true)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CATEGORY',v_id,'CATEGORY_CREATED',null,
    (select to_jsonb(c) from public.categories c where c.id=v_id),'ADMIN');

  return (select to_jsonb(c) from public.categories c where c.id=v_id);
end;
$$;

create or replace function public.service_admin_update_category_audited(
  p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_sort_order integer, p_is_active boolean, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='CATEGORY_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='CATEGORY_SLUG_INVALID'; end if;

  select to_jsonb(c) into v_before from public.categories c where c.id=p_category_id for update;
  if v_before is null then raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND'; end if;

  update public.categories set name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    sort_order=coalesce(p_sort_order,0),is_active=coalesce(p_is_active,true),updated_at=now()
  where id=p_category_id;
  select to_jsonb(c) into v_after from public.categories c where c.id=p_category_id;

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_category_audited(p_category_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_has_services boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  select to_jsonb(c) into v_before from public.categories c where c.id=p_category_id for update;
  if v_before is null then raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND'; end if;
  select exists(select 1 from public.services where category_id=p_category_id) into v_has_services;
  if v_has_services then
    update public.categories set is_active=false,updated_at=now() where id=p_category_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_ARCHIVED',v_before,
      (select to_jsonb(c) from public.categories c where c.id=p_category_id),'ADMIN');
    return jsonb_build_object('category_id',p_category_id,'removed',false,'archived',true);
  end if;
  delete from public.categories where id=p_category_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('category_id',p_category_id,'removed',true,'archived',false);
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
    p_price_per_extra_person,true,coalesce((select max(sort_order)+10 from public.services where category_id=p_category_id),0),v_mode,v_scope)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,(select to_jsonb(s) from public.services s where s.id=v_id),'ADMIN');
  return (select to_jsonb(s) from public.services s where s.id=v_id);
end;
$$;

create or replace function public.service_admin_update_service_catalog_audited(
  p_service_id uuid, p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_short_description text, p_full_description text, p_minimum_people integer,
  p_maximum_people integer, p_price_per_extra_person numeric, p_is_active boolean,
  p_sort_order integer, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_category_scope text;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select operation_scope into v_category_scope from public.categories where id=p_category_id and is_active;
  if not found then raise exception using errcode='P0001', message='CATEGORY_NOT_AVAILABLE'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') or v_category_scope<>v_scope then raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001', message='INVALID_PEOPLE_RANGE'; end if;
  if coalesce(p_price_per_extra_person,-1)<0 then raise exception using errcode='P0001', message='INVALID_PRICE'; end if;

  select to_jsonb(s) into v_before from public.services s where s.id=p_service_id for update;
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  update public.services set category_id=p_category_id,name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    short_description=nullif(btrim(p_short_description),''),full_description=nullif(btrim(p_full_description),''),
    minimum_people=p_minimum_people,maximum_people=p_maximum_people,price_per_extra_person=p_price_per_extra_person,
    is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
  where id=p_service_id;
  select to_jsonb(s) into v_after from public.services s where s.id=p_service_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CATALOG_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_replace_day_time_pricing_audited(
  p_service_id uuid, p_rules jsonb, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_rule jsonb;
  v_action text;
  v_days smallint[];
  v_idx integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_rules,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='PRICING_RULES_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority,pr.id),'[]'::jsonb) into v_before
  from public.pricing_rules pr where pr.service_id=p_service_id and pr.rule_scope='DAY_TIME';
  delete from public.pricing_rules where service_id=p_service_id and rule_scope='DAY_TIME';

  for v_rule in select value from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) loop
    v_action := upper(btrim(coalesce(v_rule->>'action_type','')));
    if v_action not in ('REPLACE_PRICE','ADD_AMOUNT','ADD_PERCENT') then raise exception using errcode='P0001', message='PRICING_ACTION_INVALID'; end if;
    if nullif(btrim(v_rule->>'name'),'') is null then raise exception using errcode='P0001', message='PRICING_RULE_NAME_REQUIRED'; end if;
    if jsonb_typeof(coalesce(v_rule->'days_of_week','[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='PRICING_DAYS_INVALID'; end if;
    select coalesce(array_agg(value::smallint order by value::smallint),'{}'::smallint[]) into v_days
    from jsonb_array_elements_text(coalesce(v_rule->'days_of_week','[]'::jsonb));
    if exists(select 1 from unnest(v_days) d where d<0 or d>6) then raise exception using errcode='P0001', message='PRICING_DAYS_INVALID'; end if;

    insert into public.pricing_rules(service_id,name,rule_scope,days_of_week,start_local_time,end_local_time,
      valid_from_date,valid_until_date,action_type,amount,percentage,priority,is_active)
    values(p_service_id,btrim(v_rule->>'name'),'DAY_TIME',case when cardinality(v_days)=0 then null else v_days end,
      case when nullif(v_rule->>'start_local_time','') is null then null else (v_rule->>'start_local_time')::time end,
      case when nullif(v_rule->>'end_local_time','') is null then null else (v_rule->>'end_local_time')::time end,
      case when nullif(v_rule->>'valid_from_date','') is null then null else (v_rule->>'valid_from_date')::date end,
      case when nullif(v_rule->>'valid_until_date','') is null then null else (v_rule->>'valid_until_date')::date end,
      v_action,
      case when v_action in ('REPLACE_PRICE','ADD_AMOUNT') then (v_rule->>'amount')::numeric else null end,
      case when v_action='ADD_PERCENT' then (v_rule->>'percentage')::numeric else null end,
      coalesce((v_rule->>'priority')::integer,100+v_idx),coalesce((v_rule->>'is_active')::boolean,true));
    v_idx := v_idx+1;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority,pr.id),'[]'::jsonb) into v_after
  from public.pricing_rules pr where pr.service_id=p_service_id and pr.rule_scope='DAY_TIME';
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_DAY_TIME_PRICING_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_create_extra_audited(
  p_name text,p_description text,p_price numeric,p_duration_delta_minutes integer,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='EXTRA_NAME_REQUIRED'; end if;
  if coalesce(p_price,-1)<0 or coalesce(p_duration_delta_minutes,-1)<0 then raise exception using errcode='P0001', message='EXTRA_VALUE_INVALID'; end if;
  insert into public.extras(name,description,price,duration_delta_minutes,is_active)
  values(btrim(p_name),nullif(btrim(p_description),''),p_price,p_duration_delta_minutes,true) returning id into v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EXTRA',v_id,'EXTRA_CREATED',null,(select to_jsonb(e) from public.extras e where e.id=v_id),'ADMIN');
  return (select to_jsonb(e) from public.extras e where e.id=v_id);
end;
$$;

create or replace function public.service_admin_update_extra_audited(
  p_extra_id uuid,p_name text,p_description text,p_price numeric,p_duration_delta_minutes integer,p_is_active boolean,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='EXTRA_NAME_REQUIRED'; end if;
  if coalesce(p_price,-1)<0 or coalesce(p_duration_delta_minutes,-1)<0 then raise exception using errcode='P0001', message='EXTRA_VALUE_INVALID'; end if;
  select to_jsonb(e) into v_before from public.extras e where e.id=p_extra_id for update;
  if v_before is null then raise exception using errcode='P0001', message='EXTRA_NOT_FOUND'; end if;
  update public.extras set name=btrim(p_name),description=nullif(btrim(p_description),''),price=p_price,
    duration_delta_minutes=p_duration_delta_minutes,is_active=coalesce(p_is_active,true),updated_at=now() where id=p_extra_id;
  select to_jsonb(e) into v_after from public.extras e where e.id=p_extra_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_extra_audited(p_extra_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_in_use boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select to_jsonb(e) into v_before from public.extras e where e.id=p_extra_id for update;
  if v_before is null then raise exception using errcode='P0001', message='EXTRA_NOT_FOUND'; end if;
  select exists(select 1 from public.service_extras where extra_id=p_extra_id)
      or exists(select 1 from public.appointment_extras where extra_id=p_extra_id) into v_in_use;
  if v_in_use then
    update public.extras set is_active=false,updated_at=now() where id=p_extra_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_ARCHIVED',v_before,(select to_jsonb(e) from public.extras e where e.id=p_extra_id),'ADMIN');
    return jsonb_build_object('extra_id',p_extra_id,'removed',false,'archived',true);
  end if;
  delete from public.extras where id=p_extra_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('extra_id',p_extra_id,'removed',true,'archived',false);
end;
$$;

create or replace function public.service_admin_replace_service_extras_audited(
  p_service_id uuid,p_extras jsonb,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_after jsonb; v_item jsonb; v_extra_id uuid; v_placement text; v_idx integer:=0;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_extras,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='SERVICE_EXTRAS_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(se) order by se.sort_order,se.extra_id),'[]'::jsonb) into v_before from public.service_extras se where se.service_id=p_service_id;
  delete from public.service_extras where service_id=p_service_id;
  for v_item in select value from jsonb_array_elements(coalesce(p_extras,'[]'::jsonb)) loop
    v_extra_id := (v_item->>'extra_id')::uuid;
    v_placement := upper(btrim(coalesce(v_item->>'schedule_placement','APPEND')));
    if v_placement not in ('PREPEND','APPEND') then raise exception using errcode='P0001', message='EXTRA_SCHEDULE_PLACEMENT_INVALID'; end if;
    if not exists(select 1 from public.extras where id=v_extra_id and is_active) then raise exception using errcode='P0001', message='EXTRA_NOT_AVAILABLE'; end if;
    insert into public.service_extras(service_id,extra_id,sort_order,is_required,max_quantity,schedule_placement,default_schedule_minutes,schedule_updated_at)
    values(p_service_id,v_extra_id,coalesce((v_item->>'sort_order')::integer,v_idx*10),
      coalesce((v_item->>'is_required')::boolean,false),coalesce((v_item->>'max_quantity')::integer,1),v_placement,
      case when nullif(v_item->>'default_schedule_minutes','') is null then null else (v_item->>'default_schedule_minutes')::integer end,now());
    v_idx:=v_idx+1;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(se) order by se.sort_order,se.extra_id),'[]'::jsonb) into v_after from public.service_extras se where se.service_id=p_service_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_EXTRAS_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

-- Simple per-extra-person pricing is applied after day/time pricing and before optional legacy PEOPLE rules.
create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_extra_duration integer := 0;
  v_duration integer := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_pricing_version text;
  r record;
begin
  select s.* into v_service from public.services s where s.id=p_service_id and s.is_active;
  if not found then raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE'; end if;
  if not exists(select 1 from public.service_employees se where se.id=p_service_employee_id and se.service_id=p_service_id and se.is_active) then
    raise exception using errcode='P0001', message='EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;
  if p_people_count<v_service.minimum_people then raise exception using errcode='P0001', message='PEOPLE_BELOW_MINIMUM'; end if;
  if p_people_count>v_service.maximum_people then raise exception using errcode='P0001', message='PEOPLE_ABOVE_MAXIMUM'; end if;
  if jsonb_typeof(coalesce(p_extra_selections,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='INVALID_EXTRA'; end if;
  select count(*) into v_requested_extras from jsonb_array_elements(coalesce(p_extra_selections,'[]'::jsonb));
  if exists(select 1 from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer) group by x.extra_id having count(*)>1) then
    raise exception using errcode='P0001', message='INVALID_EXTRA';
  end if;

  v_price:=v_service.base_price;
  v_duration:=v_service.base_duration_minutes;
  for r in
    select e.id extra_id,e.price,e.duration_delta_minutes,x.quantity,se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer)
    join public.service_extras se on se.service_id=p_service_id and se.extra_id=x.extra_id
    join public.extras e on e.id=x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity<1 or r.quantity>r.max_quantity then raise exception using errcode='P0001', message='INVALID_EXTRA_QUANTITY'; end if;
    v_processed_extras:=v_processed_extras+1;
    v_extras_total:=v_extras_total+(r.price*r.quantity);
    v_extra_duration:=v_extra_duration+(r.duration_delta_minutes*r.quantity);
  end loop;
  if v_processed_extras<>v_requested_extras then raise exception using errcode='P0001', message='INVALID_EXTRA'; end if;

  select os.timezone into v_timezone from public.operation_settings os where os.id=1;
  if p_requested_start_at is not null then
    v_local_ts:=p_requested_start_at at time zone v_timezone;
    v_local_date:=v_local_ts::date; v_local_time:=v_local_ts::time; v_dow:=extract(dow from v_local_ts)::smallint;
    for r in select pr.* from public.pricing_rules pr where pr.service_id=p_service_id and pr.is_active and pr.rule_scope='DAY_TIME'
      and (pr.valid_from_date is null or v_local_date>=pr.valid_from_date)
      and (pr.valid_until_date is null or v_local_date<=pr.valid_until_date)
      and (pr.days_of_week is null or v_dow=any(pr.days_of_week))
      and (pr.start_local_time is null or v_local_time>=pr.start_local_time)
      and (pr.end_local_time is null or v_local_time<pr.end_local_time)
      order by pr.priority asc,pr.id asc
    loop
      if r.action_type='REPLACE_PRICE' then v_price:=r.amount;
      elsif r.action_type='ADD_AMOUNT' then v_price:=v_price+r.amount;
      elsif r.action_type='ADD_PERCENT' then v_price:=v_price*(1+(r.percentage/100)); end if;
    end loop;
  end if;
  v_after_day_time:=round(greatest(v_price,0),2);
  v_day_time_adjustment:=v_after_day_time-v_service.base_price;
  v_price:=v_after_day_time + greatest(p_people_count-v_service.minimum_people,0)*v_service.price_per_extra_person;

  for r in select pr.* from public.pricing_rules pr where pr.service_id=p_service_id and pr.is_active and pr.rule_scope='PEOPLE'
    and p_people_count between pr.min_people and pr.max_people
    and (pr.valid_from_date is null or coalesce(v_local_date,current_date)>=pr.valid_from_date)
    and (pr.valid_until_date is null or coalesce(v_local_date,current_date)<=pr.valid_until_date)
    order by pr.priority asc,pr.id asc
  loop
    if r.action_type='REPLACE_PRICE' then v_price:=r.amount;
    elsif r.action_type='ADD_AMOUNT' then v_price:=v_price+r.amount;
    elsif r.action_type='ADD_PERCENT' then v_price:=v_price*(1+(r.percentage/100)); end if;
  end loop;
  v_after_people:=round(greatest(v_price,0),2);
  v_people_adjustment:=v_after_people-v_after_day_time;
  v_extras_total:=round(v_extras_total,2);
  v_duration:=v_duration+v_extra_duration;
  v_subtotal:=round(greatest(v_after_people+v_extras_total,0),2);

  if p_coupon_code is not null and btrim(p_coupon_code)<>'' then
    select c.* into v_coupon from public.coupons c where lower(c.code)=lower(btrim(p_coupon_code)) and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at,now())>=c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at,now())<=c.valid_until)
      and (not exists(select 1 from public.coupon_services cs where cs.coupon_id=c.id)
        or exists(select 1 from public.coupon_services cs where cs.coupon_id=c.id and cs.service_id=p_service_id)) limit 1;
    if not found then raise exception using errcode='P0001', message='INVALID_COUPON'; end if;
    if v_coupon.discount_type='FIXED' then v_coupon_discount:=least(v_coupon.discount_value,v_subtotal);
    else v_coupon_discount:=round(v_subtotal*(v_coupon.discount_value/100),2); end if;
  end if;
  v_coupon_discount:=round(v_coupon_discount,2);
  v_commercial_value:=round(greatest(v_subtotal-v_coupon_discount,0),2);

  select coalesce(array_agg(distinct resource_id order by resource_id),'{}'::uuid[]) into v_resource_ids
  from (
    select sr.resource_id from public.service_resources sr where sr.service_id=p_service_id and sr.is_required
    union
    select er.resource_id from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer)
      join public.extra_resources er on er.extra_id=x.extra_id and er.is_required
  ) required_resources;

  select md5(concat_ws('|',v_service.updated_at::text,
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id=p_service_id),''),
    coalesce((select max(e.updated_at)::text from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer) join public.extras e on e.id=x.extra_id),''),
    coalesce(v_coupon.updated_at::text,''))) into v_pricing_version;

  return jsonb_build_object('service_id',p_service_id,'service_employee_id',p_service_employee_id,'duration_minutes',v_duration,
    'buffer_before_minutes',v_service.buffer_before_minutes,'buffer_after_minutes',v_service.buffer_after_minutes,
    'resource_ids',to_jsonb(v_resource_ids),'base_price',round(v_service.base_price,2),
    'day_time_adjustment',round(v_day_time_adjustment,2),'people_adjustment',round(v_people_adjustment,2),
    'extras_total',v_extras_total,'coupon_discount',v_coupon_discount,'commercial_value',v_commercial_value,'pricing_version',v_pricing_version);
end;
$$;

revoke all on function public.service_admin_list_categories() from public,anon,authenticated;
revoke all on function public.service_admin_list_extras() from public,anon,authenticated;
revoke all on function public.service_admin_create_category_audited(text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_category_audited(uuid,text,text,text,integer,boolean,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_category_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_day_time_pricing_audited(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_create_extra_audited(text,text,numeric,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_extra_audited(uuid,text,text,numeric,integer,boolean,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_extra_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_service_extras_audited(uuid,jsonb,uuid) from public,anon,authenticated;

grant execute on function public.service_admin_list_categories() to service_role;
grant execute on function public.service_admin_list_extras() to service_role;
grant execute on function public.service_admin_create_category_audited(text,text,text,uuid) to service_role;
grant execute on function public.service_admin_update_category_audited(uuid,text,text,text,integer,boolean,uuid) to service_role;
grant execute on function public.service_admin_remove_category_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid) to service_role;
grant execute on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid) to service_role;
grant execute on function public.service_admin_replace_day_time_pricing_audited(uuid,jsonb,uuid) to service_role;
grant execute on function public.service_admin_create_extra_audited(text,text,numeric,integer,uuid) to service_role;
grant execute on function public.service_admin_update_extra_audited(uuid,text,text,numeric,integer,boolean,uuid) to service_role;
grant execute on function public.service_admin_remove_extra_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_replace_service_extras_audited(uuid,jsonb,uuid) to service_role;
