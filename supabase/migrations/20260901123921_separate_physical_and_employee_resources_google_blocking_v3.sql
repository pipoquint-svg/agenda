-- Separate shared PHYSICAL studio capacity from per-active-employee PERSON availability.

insert into public.resources (name, resource_type, is_active)
select 'Agenda BlackSheep', 'PERSON'::public.resource_type, true
where not exists (select 1 from public.resources where name='Agenda BlackSheep');

insert into public.resources (name, resource_type, is_active)
select 'Sabrina Pierri', 'PERSON'::public.resource_type, true
where not exists (select 1 from public.resources where name='Sabrina Pierri');

insert into public.resources (name, resource_type, is_active)
select 'Jheneffe Pierri', 'PERSON'::public.resource_type, true
where not exists (select 1 from public.resources where name='Jheneffe Pierri');

update public.employees
set resource_id = (select id from public.resources where name='Agenda BlackSheep' and resource_type='PERSON'),
    updated_at = now()
where name='Agenda BlackSheep' and is_active;

update public.employees
set resource_id = (select id from public.resources where name='Sabrina Pierri' and resource_type='PERSON'),
    updated_at = now()
where name='Sabrina Pierri' and is_active;

update public.employees
set resource_id = (select id from public.resources where name='Jheneffe Pierri' and resource_type='PERSON'),
    updated_at = now()
where name='Jheneffe Pierri' and is_active;

insert into public.service_resources (service_id, resource_id, is_required)
select distinct se.service_id, studio.id, true
from public.service_employees se
join public.employees e on e.id=se.employee_id and e.is_active
join public.services s on s.id=se.service_id and s.is_active
cross join lateral (
  select r.id from public.resources r
  where r.name='BlackSheep Estúdio Criativo'
    and r.resource_type='PHYSICAL'
    and r.is_active
  limit 1
) studio
where se.is_active
  and e.name in ('Agenda BlackSheep','Sabrina Pierri','Jheneffe Pierri')
on conflict (service_id,resource_id)
do update set is_required=excluded.is_required;

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
set search_path to 'public'
as $function$
declare
  v_quote jsonb;
  v_profile jsonb;
  v_core_duration integer;
  v_pre integer;
  v_post integer;
  v_schedule_version text;
  v_pricing_version text;
  v_employee_resource_id uuid;
  v_resource_ids uuid[] := '{}'::uuid[];
begin
  v_quote := public.calculate_booking_quote_catalog_base(
    p_service_id,p_service_employee_id,p_extra_selections,p_people_count,p_requested_start_at,p_coupon_code
  );

  select e.resource_id into v_employee_resource_id
  from public.service_employees se
  join public.employees e on e.id=se.employee_id
  where se.id=p_service_employee_id
    and se.service_id=p_service_id
    and se.is_active;

  select coalesce(array_agg(distinct x.resource_id order by x.resource_id),'{}'::uuid[])
  into v_resource_ids
  from (
    select value::uuid as resource_id
    from jsonb_array_elements_text(coalesce(v_quote->'resource_ids','[]'::jsonb))
    union all
    select v_employee_resource_id where v_employee_resource_id is not null
  ) x;

  select base_duration_minutes into v_core_duration
  from public.services where id=p_service_id;

  v_profile:=public.resolve_extra_schedule_profile(p_service_id,p_extra_selections,p_requested_start_at);
  v_pre:=coalesce((v_profile->>'pre_service_minutes')::integer,0);
  v_post:=coalesce((v_profile->>'post_service_minutes')::integer,0);
  v_schedule_version:=coalesce(v_profile->>'schedule_version','');
  v_pricing_version:=md5(coalesce(v_quote->>'pricing_version','')||'|'||v_schedule_version);

  return v_quote||jsonb_build_object(
    'resource_ids',to_jsonb(v_resource_ids),
    'core_duration_minutes',v_core_duration,
    'pre_service_minutes',v_pre,
    'post_service_minutes',v_post,
    'duration_minutes',v_core_duration+v_pre+v_post,
    'schedule_profile',v_profile,
    'pricing_version',v_pricing_version
  );
end;
$function$;

comment on column public.employees.resource_id is
'Per-active-employee PERSON availability resource. Shared PHYSICAL resources such as the studio belong in service_resources.';
