-- Module-level administrative permissions and operational dashboard read model.

create table public.admin_user_permissions (
  admin_user_id uuid not null references public.admin_users(id) on delete cascade,
  module_key text not null check (module_key in ('DASHBOARD','AGENDA','CLIENTS','FINANCE','PACKAGES','SERVICES','INTEGRATIONS','AMELIA','TEAM')),
  can_access boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (admin_user_id, module_key)
);

alter table public.admin_user_permissions enable row level security;

create policy admin_user_permissions_self_select
  on public.admin_user_permissions
  for select
  to authenticated
  using (
    exists (
      select 1 from public.admin_users au
      where au.id = admin_user_id
        and au.auth_user_id = auth.uid()
        and au.is_active
    )
  );

-- Preserve current access for existing admins. Future team members can be restricted per module.
insert into public.admin_user_permissions (admin_user_id, module_key, can_access)
select au.id, module_key, true
from public.admin_users au
cross join unnest(array['DASHBOARD','AGENDA','CLIENTS','FINANCE','PACKAGES','SERVICES','INTEGRATIONS','AMELIA','TEAM']) module_key
on conflict (admin_user_id, module_key) do nothing;

create or replace function public.service_admin_get_permissions(p_admin_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'admin_user_id', au.id,
    'display_name', au.display_name,
    'role', au.role,
    'permissions', coalesce((
      select jsonb_object_agg(p.module_key, case when au.role = 'OWNER' then true else p.can_access end)
      from public.admin_user_permissions p
      where p.admin_user_id = au.id
    ), '{}'::jsonb)
  )
  from public.admin_users au
  where au.id = p_admin_user_id and au.is_active;
$$;

create or replace function public.service_admin_set_permission(
  p_target_admin_user_id uuid,
  p_module_key text,
  p_can_access boolean,
  p_actor_admin_user_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_module text := upper(btrim(coalesce(p_module_key,'')));
  v_actor_role text;
  v_target_role text;
begin
  select role into v_actor_role from public.admin_users where id = p_actor_admin_user_id and is_active;
  if v_actor_role is distinct from 'OWNER' then
    raise exception using errcode='P0001', message='ADMIN_TEAM_PERMISSION_DENIED';
  end if;

  if v_module not in ('DASHBOARD','AGENDA','CLIENTS','FINANCE','PACKAGES','SERVICES','INTEGRATIONS','AMELIA','TEAM') then
    raise exception using errcode='P0001', message='ADMIN_MODULE_INVALID';
  end if;

  select role into v_target_role from public.admin_users where id = p_target_admin_user_id and is_active;
  if v_target_role is null then
    raise exception using errcode='P0001', message='ADMIN_USER_NOT_FOUND';
  end if;

  if v_target_role = 'OWNER' and not p_can_access then
    raise exception using errcode='P0001', message='OWNER_PERMISSION_CANNOT_BE_REVOKED';
  end if;

  insert into public.admin_user_permissions (admin_user_id, module_key, can_access, updated_at)
  values (p_target_admin_user_id, v_module, p_can_access, now())
  on conflict (admin_user_id, module_key)
  do update set can_access = excluded.can_access, updated_at = now();

  return public.service_admin_get_permissions(p_target_admin_user_id);
end;
$$;

create or replace function public.service_admin_dashboard(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_brand_key text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_brand text := nullif(upper(btrim(coalesce(p_brand_key,''))), '');
  v_now timestamptz := now();
  v_available_minutes numeric := 0;
  v_occupied_minutes numeric := 0;
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode='P0001', message='ADMIN_DASHBOARD_INVALID_RANGE';
  end if;
  if p_end_at - p_start_at > interval '366 days' then
    raise exception using errcode='P0001', message='ADMIN_DASHBOARD_RANGE_TOO_LARGE';
  end if;
  if v_brand is not null and v_brand not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode='P0001', message='ADMIN_BRAND_FILTER_INVALID';
  end if;

  select coalesce(sum(extract(epoch from (r.end_local_time-r.start_local_time))/60),0)
  into v_available_minutes
  from public.resource_availability_rules r
  join public.resources rs on rs.id = r.resource_id and rs.is_active and rs.resource_type = 'PHYSICAL'
  cross join generate_series(
    (p_start_at at time zone 'America/Sao_Paulo')::date,
    ((p_end_at - interval '1 second') at time zone 'America/Sao_Paulo')::date,
    interval '1 day'
  ) d
  where r.is_active
    and r.weekday = extract(dow from d)::smallint;

  select coalesce(sum(extract(epoch from (
    least(upper(ra.occupied_range), p_end_at) - greatest(lower(ra.occupied_range), p_start_at)
  ))/60),0)
  into v_occupied_minutes
  from public.resource_allocations ra
  join public.resources rs on rs.id = ra.resource_id and rs.is_active and rs.resource_type = 'PHYSICAL'
  left join public.appointments a on a.id = ra.appointment_id
  where ra.status not in ('RELEASED','CANCELLED','EXPIRED','IGNORED_BY_ADMIN')
    and lower(ra.occupied_range) < p_end_at
    and upper(ra.occupied_range) > p_start_at
    and (
      v_brand is null
      or a.id is null
      or exists (
        select 1
        from public.booking_page_services bps
        join public.booking_pages bp on bp.id=bps.booking_page_id and bp.is_active
        where bps.service_id=a.service_id and bps.is_active and bp.brand_key=v_brand
      )
    );

  return jsonb_build_object(
    'range', jsonb_build_object('start_at',p_start_at,'end_at',p_end_at,'brand_key',v_brand),
    'new_bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',a.id,'public_code',a.public_code,'created_at',a.created_at,'start_at',a.start_at,'status',a.status,
        'service_name',coalesce(a.service_name_snapshot,s.name),'customer_name',c.name,'employee_name',e.name
      ) order by a.created_at desc)
      from public.appointments a
      left join public.services s on s.id=a.service_id
      left join public.customers c on c.id=a.primary_customer_id
      left join public.service_employees se on se.id=a.service_employee_id
      left join public.employees e on e.id=se.employee_id
      where a.deleted_at is null and a.status <> 'DRAFT'
        and a.created_at >= p_start_at and a.created_at < p_end_at
        and (v_brand is null or exists (
          select 1 from public.booking_page_services bps join public.booking_pages bp on bp.id=bps.booking_page_id
          where bps.service_id=a.service_id and bps.is_active and bp.is_active and bp.brand_key=v_brand
        ))
    ),'[]'::jsonb),
    'pending_notifications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',a.id,'public_code',a.public_code,'start_at',a.start_at,'status',a.status,'financial_status',a.financial_status,
        'service_name',coalesce(a.service_name_snapshot,s.name),'customer_name',c.name,
        'kind',case when a.status='AWAITING_PAYMENT' then 'PAYMENT_PENDING' when a.status='HELD' then 'HOLD_PENDING' else 'FINANCIAL_PENDING' end
      ) order by a.start_at)
      from public.appointments a
      left join public.services s on s.id=a.service_id
      left join public.customers c on c.id=a.primary_customer_id
      where a.deleted_at is null
        and (a.status in ('HELD','AWAITING_PAYMENT') or a.financial_status in ('PENDING','PARTIALLY_PAID'))
        and a.status not in ('CANCELLED','EXPIRED','COMPLETED')
        and a.start_at >= v_now - interval '1 day'
        and (v_brand is null or exists (
          select 1 from public.booking_page_services bps join public.booking_pages bp on bp.id=bps.booking_page_id
          where bps.service_id=a.service_id and bps.is_active and bp.is_active and bp.brand_key=v_brand
        ))
    ),'[]'::jsonb),
    'upcoming_rentals_3d', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',a.id,'public_code',a.public_code,'start_at',a.start_at,'end_at',a.end_at,'status',a.status,
        'service_name',coalesce(a.service_name_snapshot,s.name),'customer_name',c.name,'employee_name',e.name
      ) order by a.start_at)
      from public.appointments a
      left join public.services s on s.id=a.service_id
      left join public.customers c on c.id=a.primary_customer_id
      left join public.service_employees se on se.id=a.service_employee_id
      left join public.employees e on e.id=se.employee_id
      where a.deleted_at is null and a.status in ('AWAITING_PAYMENT','CONFIRMED')
        and a.start_at >= v_now and a.start_at < v_now + interval '3 days'
        and exists (
          select 1 from public.booking_page_services bps join public.booking_pages bp on bp.id=bps.booking_page_id
          where bps.service_id=a.service_id and bps.is_active and bp.is_active and bp.brand_key='BLACKSHEEP'
        )
    ),'[]'::jsonb),
    'occupancy', jsonb_build_object(
      'occupied_minutes',round(v_occupied_minutes,2),
      'available_minutes',round(v_available_minutes,2),
      'rate_percent',case when v_available_minutes > 0 then round(least(100,(v_occupied_minutes/v_available_minutes)*100),2) else null end
    ),
    'by_employee', coalesce((
      select jsonb_agg(jsonb_build_object(
        'employee_id',x.employee_id,'employee_name',x.employee_name,'appointments',x.appointments,'booked_minutes',x.booked_minutes
      ) order by x.appointments desc,x.employee_name)
      from (
        select e.id employee_id, coalesce(e.name,'Sem funcionário') employee_name,
          count(*)::int appointments,
          coalesce(sum(extract(epoch from (a.end_at-a.start_at))/60),0)::int booked_minutes
        from public.appointments a
        left join public.service_employees se on se.id=a.service_employee_id
        left join public.employees e on e.id=se.employee_id
        where a.deleted_at is null and a.status in ('AWAITING_PAYMENT','CONFIRMED','COMPLETED')
          and a.start_at < p_end_at and a.end_at > p_start_at
          and (v_brand is null or exists (
            select 1 from public.booking_page_services bps join public.booking_pages bp on bp.id=bps.booking_page_id
            where bps.service_id=a.service_id and bps.is_active and bp.is_active and bp.brand_key=v_brand
          ))
        group by e.id,e.name
      ) x
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on public.admin_user_permissions from anon;
grant select on public.admin_user_permissions to authenticated;
grant all on public.admin_user_permissions to service_role;

revoke all on function public.service_admin_get_permissions(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_set_permission(uuid,text,boolean,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_dashboard(timestamptz,timestamptz,text) from public, anon, authenticated;
grant execute on function public.service_admin_get_permissions(uuid) to service_role;
grant execute on function public.service_admin_set_permission(uuid,text,boolean,uuid) to service_role;
grant execute on function public.service_admin_dashboard(timestamptz,timestamptz,text) to service_role;
