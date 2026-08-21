-- Authenticated admin read models. These are intentionally service-role only;
-- the Edge Function validates the Supabase user against admin_users.

create or replace function public.service_admin_list_agenda(
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_INVALID_RANGE';
  end if;

  if p_end_at - p_start_at > interval '31 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_RANGE_TOO_LARGE';
  end if;

  return jsonb_build_object(
    'range', jsonb_build_object('start_at', p_start_at, 'end_at', p_end_at),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'public_code', a.public_code,
        'status', a.status,
        'financial_status', a.financial_status,
        'start_at', a.start_at,
        'end_at', a.end_at,
        'duration_minutes', a.duration_minutes,
        'people_count', a.people_count,
        'origin', a.origin,
        'service_name', coalesce(a.service_name_snapshot, s.name),
        'employee_name', e.name,
        'customer', jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'phone', c.phone,
          'email', c.email
        ),
        'commercial_value', a.commercial_value,
        'financial', public.get_appointment_financial_summary(a.id),
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'type', r.resource_type) order by r.name)
          from public.resource_allocations ra
          join public.resources r on r.id = ra.resource_id
          where ra.appointment_id = a.id
            and ra.allocation_type = 'APPOINTMENT'
            and ra.status not in ('RELEASED','CANCELLED','EXPIRED')
        ), '[]'::jsonb)
      ) order by a.start_at, a.public_code)
      from public.appointments a
      left join public.services s on s.id = a.service_id
      left join public.service_employees se on se.id = a.service_employee_id
      left join public.employees e on e.id = se.employee_id
      left join public.customers c on c.id = a.primary_customer_id
      where a.deleted_at is null
        and a.status <> 'DRAFT'
        and a.start_at < p_end_at
        and a.end_at > p_start_at
    ), '[]'::jsonb),
    'external_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'allocation_id', ra.id,
        'resource_id', r.id,
        'resource_name', r.name,
        'start_at', lower(ra.occupied_range),
        'end_at', upper(ra.occupied_range),
        'status', ra.status,
        'reason', ra.reason,
        'source', coalesce(ra.external_source, 'GOOGLE'),
        'calendar_name', gc.name,
        'event_summary', gce.summary,
        'event_qualification', gce.qualification
      ) order by lower(ra.occupied_range), r.name)
      from public.resource_allocations ra
      join public.resources r on r.id = ra.resource_id
      left join public.google_calendar_events gce on gce.id = ra.google_calendar_event_id
      left join public.google_calendars gc on gc.id = gce.google_calendar_id
      where ra.allocation_type = 'EXTERNAL_BLOCK'
        and ra.status = 'EXTERNAL_ACTIVE'
        and lower(ra.occupied_range) < p_end_at
        and upper(ra.occupied_range) > p_start_at
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_a public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_service public.services%rowtype;
  v_employee_name text;
begin
  select * into v_a
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_a.primary_customer_id;
  select * into v_service from public.services where id = v_a.service_id;
  select e.name into v_employee_name
  from public.service_employees se
  join public.employees e on e.id = se.employee_id
  where se.id = v_a.service_employee_id;

  return jsonb_build_object(
    'appointment', jsonb_build_object(
      'id', v_a.id,
      'public_code', v_a.public_code,
      'status', v_a.status,
      'financial_status', v_a.financial_status,
      'start_at', v_a.start_at,
      'end_at', v_a.end_at,
      'duration_minutes', v_a.duration_minutes,
      'people_count', v_a.people_count,
      'origin', v_a.origin,
      'version', v_a.version,
      'service_name', coalesce(v_a.service_name_snapshot, v_service.name),
      'service_description', coalesce(v_a.service_description_snapshot, v_service.full_description),
      'employee_name', v_employee_name,
      'commercial_value', v_a.commercial_value,
      'base_price', v_a.base_price_snapshot,
      'variable_price_adjustment', v_a.variable_price_adjustment,
      'extras_total', v_a.extras_total,
      'coupon_discount', v_a.coupon_discount,
      'hold_expires_at', v_a.hold_expires_at,
      'confirmed_at', v_a.confirmed_at,
      'completed_at', v_a.completed_at,
      'cancelled_at', v_a.cancelled_at,
      'cancel_reason', v_a.cancel_reason,
      'attendance_status', v_a.attendance_status
    ),
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone,
      'cpf_cnpj', v_customer.cpf_cnpj,
      'customer_type', v_customer.customer_type
    ) end,
    'financial', public.get_appointment_financial_summary(v_a.id),
    'extras', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ae.id,
        'extra_id', ae.extra_id,
        'name', ae.name_snapshot,
        'quantity', ae.quantity,
        'unit_price', ae.unit_price_snapshot,
        'total_price', ae.total_price,
        'duration_delta_minutes', ae.total_duration_delta
      ) order by ae.created_at, ae.id)
      from public.appointment_extras ae
      where ae.appointment_id = v_a.id
    ), '[]'::jsonb),
    'answers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', aa.id,
        'field_key', aa.field_key_snapshot,
        'label', aa.label_snapshot,
        'value', aa.value_json
      ) order by aa.created_at, aa.id)
      from public.appointment_answers aa
      where aa.appointment_id = v_a.id
    ), '[]'::jsonb),
    'terms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'terms_version_id', ata.terms_version_id,
        'name', tv.name,
        'version', tv.version,
        'accepted_at', ata.accepted_at,
        'content_snapshot', ata.content_snapshot
      ) order by ata.accepted_at, ata.id)
      from public.appointment_term_acceptances ata
      left join public.terms_versions tv on tv.id = ata.terms_version_id
      where ata.appointment_id = v_a.id
    ), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pt.id,
        'transaction_type', pt.transaction_type,
        'method', pt.method,
        'provider', pt.provider,
        'provider_payment_id', pt.provider_payment_id,
        'status', pt.status,
        'contract_amount_settled', pt.contract_amount_settled,
        'payment_discount_amount', pt.payment_discount_amount,
        'cash_amount', pt.cash_amount,
        'paid_at', pt.paid_at,
        'notes', pt.notes,
        'created_at', pt.created_at
      ) order by pt.created_at, pt.id)
      from public.payment_transactions pt
      where pt.appointment_id = v_a.id
    ), '[]'::jsonb),
    'package_usage', (
      select jsonb_build_object(
        'hour_package_id', apu.hour_package_id,
        'package_name', hp.name,
        'required_seconds', apu.required_seconds,
        'surcharge_seconds', apu.surcharge_seconds,
        'charged_seconds', apu.charged_seconds,
        'is_special_period', apu.is_special_period,
        'cash_due', apu.cash_due,
        'reversed_at', apu.reversed_at
      )
      from public.appointment_package_usage apu
      join public.hour_packages hp on hp.id = apu.hour_package_id
      where apu.appointment_id = v_a.id
    ),
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'allocation_id', ra.id,
        'resource_id', r.id,
        'resource_name', r.name,
        'resource_type', r.resource_type,
        'status', ra.status,
        'start_at', lower(ra.occupied_range),
        'end_at', upper(ra.occupied_range)
      ) order by r.name)
      from public.resource_allocations ra
      join public.resources r on r.id = ra.resource_id
      where ra.appointment_id = v_a.id
        and ra.allocation_type = 'APPOINTMENT'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.service_admin_list_amelia_history(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := nullif(lower(btrim(p_search)), '');
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_AMELIA_INVALID_RANGE';
  end if;

  if p_end_at - p_start_at > interval '366 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_AMELIA_RANGE_TOO_LARGE';
  end if;

  return jsonb_build_object(
    'records', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', lab.id,
        'amelia_booking_id', lab.amelia_booking_id,
        'woocommerce_order_id', lab.woocommerce_order_id,
        'customer_name', lab.customer_name,
        'customer_email', lab.customer_email,
        'customer_phone', lab.customer_phone,
        'cpf_cnpj', lab.cpf_cnpj,
        'service_name', lab.service_name,
        'employee_name', lab.employee_name,
        'start_at', lab.start_at,
        'end_at', lab.end_at,
        'declared_duration_minutes', lab.declared_duration_minutes,
        'status_raw', lab.status_raw,
        'amelia_price_amount', lab.amelia_price_amount,
        'payment_status_raw', lab.payment_status_raw,
        'payment_method_raw', lab.payment_method_raw,
        'extras', lab.extras_json,
        'custom_fields', lab.custom_fields_json,
        'notes', lab.notes,
        'record_mode', lab.record_mode,
        'operational_authority', lab.operational_authority,
        'last_imported_at', lab.last_imported_at
      ) order by lab.start_at desc nulls last, lab.amelia_booking_id)
      from (
        select *
        from public.legacy_amelia_bookings x
        where x.start_at is not null
          and x.start_at >= p_start_at
          and x.start_at < p_end_at
          and (
            v_search is null
            or lower(coalesce(x.customer_name,'')) like '%' || v_search || '%'
            or lower(coalesce(x.customer_email,'')) like '%' || v_search || '%'
            or regexp_replace(coalesce(x.customer_phone,''), '\D', '', 'g') like '%' || regexp_replace(v_search, '\D', '', 'g') || '%'
            or lower(coalesce(x.service_name,'')) like '%' || v_search || '%'
            or lower(x.amelia_booking_id) like '%' || v_search || '%'
          )
        order by x.start_at desc
        limit 500
      ) lab
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.service_admin_list_agenda(timestamptz,timestamptz) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) from public, anon, authenticated;

grant execute on function public.service_admin_list_agenda(timestamptz,timestamptz) to service_role;
grant execute on function public.service_admin_get_appointment(uuid) to service_role;
grant execute on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) to service_role;

comment on function public.service_admin_list_agenda(timestamptz,timestamptz) is
  'Operational admin agenda: native appointments and active external blocks only. Amelia history is intentionally excluded.';
comment on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) is
  'Read-only Amelia legacy history. These rows are never operational appointments.';
