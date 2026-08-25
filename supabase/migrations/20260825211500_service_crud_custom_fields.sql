-- Service catalog management by operation, without category as an admin concept.
-- Keeps category_id only as legacy compatibility while all new admin writes are operation-scoped.

alter table public.service_fields drop constraint if exists service_fields_field_type_check;
alter table public.service_fields add constraint service_fields_field_type_check
  check (field_type in ('TEXT','TEXTAREA','NUMBER','DATE','SELECT','MULTISELECT','BOOLEAN'));

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
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'custom_fields', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id,
      'field_key', f.field_key,
      'label', f.label,
      'field_type', f.field_type,
      'help_text', f.help_text,
      'placeholder', f.placeholder,
      'is_required', f.is_required,
      'sort_order', f.sort_order,
      'options_json', f.options_json,
      'is_active', f.is_active
    ) order by f.sort_order, f.label, f.id)
    from public.service_fields f
    where f.service_id = s.id
  ), '[]'::jsonb),
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id,
      'min_blocks', t.min_blocks,
      'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block,
      'is_active', t.is_active,
      'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t where t.service_id = s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'block_count', p.block_count,
      'title', p.title,
      'description', p.description,
      'badge', p.badge,
      'is_featured', p.is_featured,
      'is_active', p.is_active,
      'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p where p.service_id = s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp) - 'service_id' - 'created_at' - 'updated_at'
    from public.service_change_policies cp where cp.service_id = s.id
  )
) order by case s.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end, s.sort_order, s.name), '[]'::jsonb)
from public.services s;
$$;

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
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,true,
    coalesce((select max(sort_order)+10 from public.services where operation_scope=v_scope),0),
    v_mode,v_scope
  ) returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,public.service_admin_service_snapshot(v_id),'ADMIN');
  return public.service_admin_service_snapshot(v_id);
end;
$$;

create or replace function public.service_admin_update_catalog_audited(
  p_service_id uuid,
  p_name text,
  p_slug text,
  p_operation_scope text,
  p_short_description text,
  p_full_description text,
  p_is_active boolean,
  p_sort_order integer,
  p_admin_id uuid
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
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='SERVICE_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  update public.services set
    name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    short_description=nullif(btrim(p_short_description),''),full_description=nullif(btrim(p_full_description),''),
    is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
  where id=p_service_id;

  v_after := public.service_admin_service_snapshot(p_service_id);
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CATALOG_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_service_audited(p_service_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_has_history boolean;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  select exists(select 1 from public.appointments where service_id=p_service_id)
      or exists(select 1 from public.checkout_holds where service_id=p_service_id)
      or exists(select 1 from public.pre_reservations where service_id=p_service_id)
    into v_has_history;

  if v_has_history then
    update public.services set is_active=false,updated_at=now() where id=p_service_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_ARCHIVED',v_before,public.service_admin_service_snapshot(p_service_id),'ADMIN');
    return jsonb_build_object('service_id',p_service_id,'removed',false,'archived',true);
  end if;

  delete from public.services where id=p_service_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',p_service_id,'SERVICE_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('service_id',p_service_id,'removed',true,'archived',false);
end;
$$;

create or replace function public.service_admin_replace_custom_fields_audited(
  p_service_id uuid,
  p_fields jsonb,
  p_admin_id uuid
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
  v_field jsonb;
  v_type text;
  v_key text;
  v_index integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if jsonb_typeof(coalesce(p_fields,'[]'::jsonb)) <> 'array' then raise exception using errcode='P0001', message='SERVICE_FIELDS_INVALID'; end if;
  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  delete from public.service_fields where service_id=p_service_id;
  for v_field in select value from jsonb_array_elements(coalesce(p_fields,'[]'::jsonb)) loop
    v_key := lower(btrim(coalesce(v_field->>'field_key','')));
    v_type := upper(btrim(coalesce(v_field->>'field_type','')));
    if v_key !~ '^[a-z][a-z0-9_]{1,63}$' then raise exception using errcode='P0001', message='SERVICE_FIELD_KEY_INVALID'; end if;
    if nullif(btrim(v_field->>'label'),'') is null then raise exception using errcode='P0001', message='SERVICE_FIELD_LABEL_REQUIRED'; end if;
    if v_type not in ('TEXT','TEXTAREA','NUMBER','DATE','SELECT','MULTISELECT','BOOLEAN') then raise exception using errcode='P0001', message='SERVICE_FIELD_TYPE_INVALID'; end if;
    if v_type in ('SELECT','MULTISELECT') and jsonb_typeof(coalesce(v_field->'options_json','[]'::jsonb)) <> 'array' then raise exception using errcode='P0001', message='SERVICE_FIELD_OPTIONS_INVALID'; end if;

    insert into public.service_fields(service_id,field_key,label,field_type,help_text,placeholder,is_required,sort_order,options_json,is_active)
    values(
      p_service_id,v_key,btrim(v_field->>'label'),v_type,nullif(btrim(v_field->>'help_text'),''),nullif(btrim(v_field->>'placeholder'),''),
      coalesce((v_field->>'is_required')::boolean,false),coalesce((v_field->>'sort_order')::integer,v_index*10),
      case when v_type in ('SELECT','MULTISELECT') then coalesce(v_field->'options_json','[]'::jsonb) else null end,
      coalesce((v_field->>'is_active')::boolean,true)
    );
    v_index := v_index + 1;
  end loop;

  v_after := public.service_admin_service_snapshot(p_service_id);
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CUSTOM_FIELDS_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

revoke all on function public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_catalog_audited(uuid,text,text,text,text,text,boolean,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_service_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid) to service_role;
grant execute on function public.service_admin_update_catalog_audited(uuid,text,text,text,text,text,boolean,integer,uuid) to service_role;
grant execute on function public.service_admin_remove_service_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid) to service_role;
