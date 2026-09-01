create or replace function public.service_admin_search_appointments_global(
  p_search text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_admin_id uuid;
  v_search text := btrim(coalesce(p_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 100));
  v_digits text := regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g');
  v_can_finance boolean := false;
  v_rows jsonb;
begin
  select au.id
    into v_admin_id
  from public.admin_users au
  where au.auth_user_id = auth.uid()
    and au.is_active
  limit 1;

  if v_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACCESS_DENIED';
  end if;

  if not public.service_admin_has_permission(v_admin_id, 'AGENDA_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if char_length(v_search) < 2 then
    raise exception using errcode = '22023', message = 'APPOINTMENT_SEARCH_TOO_SHORT';
  end if;

  v_can_finance := public.service_admin_has_permission(v_admin_id, 'FINANCE_VIEW');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'public_code', q.public_code,
    'status', q.status,
    'financial_status', case when v_can_finance then q.financial_status else null end,
    'start_at', q.start_at,
    'end_at', q.end_at,
    'created_at', q.created_at,
    'origin', q.origin,
    'operation_scope', q.operation_scope,
    'service_name', q.service_name,
    'employee_name', q.employee_name,
    'customer', jsonb_build_object(
      'id', q.customer_id,
      'name', q.customer_name,
      'phone', q.customer_phone,
      'email', q.customer_email
    )
  ) order by q.match_rank, q.future_rank, q.future_start, q.past_start desc, q.public_code), '[]'::jsonb)
  into v_rows
  from (
    select
      a.id,
      a.public_code,
      a.status,
      a.financial_status,
      a.start_at,
      a.end_at,
      a.created_at,
      a.origin,
      s.operation_scope,
      coalesce(a.service_name_snapshot, s.name) as service_name,
      e.name as employee_name,
      c.id as customer_id,
      c.name as customer_name,
      c.phone as customer_phone,
      c.email as customer_email,
      case
        when lower(a.public_code) = lower(v_search) then 0
        when lower(coalesce(c.email, '')) = lower(v_search) then 1
        when lower(coalesce(c.name, '')) = lower(v_search) then 2
        else 3
      end as match_rank,
      case when a.start_at >= now() then 0 else 1 end as future_rank,
      case when a.start_at >= now() then a.start_at else null end as future_start,
      case when a.start_at < now() then a.start_at else null end as past_start
    from public.appointments a
    left join public.services s on s.id = a.service_id
    left join public.service_employees se on se.id = a.service_employee_id
    left join public.employees e on e.id = se.employee_id
    left join public.customers c on c.id = a.primary_customer_id
    where a.deleted_at is null
      and a.status <> 'DRAFT'
      and (
        a.public_code ilike '%' || v_search || '%'
        or coalesce(c.name, '') ilike '%' || v_search || '%'
        or coalesce(c.email, '') ilike '%' || v_search || '%'
        or (
          char_length(v_digits) >= 2
          and regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'
        )
      )
    order by
      match_rank,
      future_rank,
      future_start asc nulls last,
      past_start desc nulls last,
      a.public_code
    limit v_limit
  ) q;

  return jsonb_build_object(
    'search', v_search,
    'limit', v_limit,
    'appointments', v_rows
  );
end;
$function$;

revoke all on function public.service_admin_search_appointments_global(text, integer) from public;
grant execute on function public.service_admin_search_appointments_global(text, integer) to authenticated;
