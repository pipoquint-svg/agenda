create or replace function public.service_admin_duplicate_service_audited(
  p_service_id uuid,
  p_name text,
  p_slug text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_source public.services%rowtype;
  v_new_id uuid;
  v_new_service_employee_id uuid;
  v_old_service_employee record;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_source from public.services where id = p_service_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if nullif(btrim(p_name), '') is null or btrim(p_name) = v_source.name then
    raise exception using errcode = 'P0001', message = 'SERVICE_DUPLICATE_NAME_REQUIRED';
  end if;
  if nullif(btrim(p_slug), '') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception using errcode = 'P0001', message = 'SERVICE_SLUG_INVALID';
  end if;
  if exists(select 1 from public.services where slug = btrim(p_slug)) then
    raise exception using errcode = 'P0001', message = 'SERVICE_SLUG_ALREADY_EXISTS';
  end if;

  insert into public.services (
    category_id, name, slug, short_description, full_description, cover_image_url,
    base_duration_minutes, buffer_before_minutes, buffer_after_minutes, base_price,
    minimum_people, maximum_people, minimum_booking_notice_minutes,
    maximum_booking_horizon_days, confirmation_percentage, checkout_hold_minutes,
    payment_hold_minutes, allow_reschedule, reschedule_min_notice_minutes,
    max_reschedules, allow_cancel, cancel_min_notice_minutes, requires_terms,
    is_active, sort_order, duration_mode, booking_block_minutes,
    minimum_booking_blocks, maximum_booking_blocks, price_per_block,
    operation_scope, booking_product_type, price_per_extra_person, service_type_id,
    checkout_minimum_payment_type, checkout_minimum_payment_value,
    slot_interval_minutes, public_minimum_booking_notice_hours,
    pix_discount_percent, payment_mode, card_max_installments
  ) values (
    v_source.category_id, btrim(p_name), btrim(p_slug), v_source.short_description,
    v_source.full_description, v_source.cover_image_url, v_source.base_duration_minutes,
    v_source.buffer_before_minutes, v_source.buffer_after_minutes, v_source.base_price,
    v_source.minimum_people, v_source.maximum_people, v_source.minimum_booking_notice_minutes,
    v_source.maximum_booking_horizon_days, v_source.confirmation_percentage,
    v_source.checkout_hold_minutes, v_source.payment_hold_minutes,
    v_source.allow_reschedule, v_source.reschedule_min_notice_minutes,
    v_source.max_reschedules, v_source.allow_cancel, v_source.cancel_min_notice_minutes,
    v_source.requires_terms, false,
    coalesce((select max(sort_order) + 10 from public.services where category_id = v_source.category_id), 0),
    v_source.duration_mode, v_source.booking_block_minutes, v_source.minimum_booking_blocks,
    v_source.maximum_booking_blocks, v_source.price_per_block, v_source.operation_scope,
    v_source.booking_product_type, v_source.price_per_extra_person, v_source.service_type_id,
    v_source.checkout_minimum_payment_type, v_source.checkout_minimum_payment_value,
    v_source.slot_interval_minutes, v_source.public_minimum_booking_notice_hours,
    v_source.pix_discount_percent, v_source.payment_mode, v_source.card_max_installments
  ) returning id into v_new_id;

  insert into public.service_change_policies (
    service_id, notice_hours,
    reschedule_first_early_percent, reschedule_first_late_percent,
    reschedule_repeat_percent, cancellation_late_percent,
    reschedule_first_early_penalty_type, reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type, reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type, reschedule_repeat_penalty_value,
    cancellation_late_penalty_type, cancellation_late_penalty_value
  )
  select v_new_id, notice_hours,
    reschedule_first_early_percent, reschedule_first_late_percent,
    reschedule_repeat_percent, cancellation_late_percent,
    reschedule_first_early_penalty_type, reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type, reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type, reschedule_repeat_penalty_value,
    cancellation_late_penalty_type, cancellation_late_penalty_value
  from public.service_change_policies where service_id = p_service_id;

  insert into public.pricing_rules (
    service_id, name, rule_scope, days_of_week, start_local_time, end_local_time,
    min_people, max_people, valid_from_date, valid_until_date, action_type,
    amount, percentage, priority, is_active
  )
  select v_new_id, name, rule_scope, days_of_week, start_local_time, end_local_time,
    min_people, max_people, valid_from_date, valid_until_date, action_type,
    amount, percentage, priority, is_active
  from public.pricing_rules where service_id = p_service_id;

  insert into public.service_duration_pricing_tiers (
    service_id, min_blocks, max_blocks, price_per_block, is_active, sort_order
  )
  select v_new_id, min_blocks, max_blocks, price_per_block, is_active, sort_order
  from public.service_duration_pricing_tiers where service_id = p_service_id;

  insert into public.service_duration_presets (
    service_id, block_count, title, description, badge, is_featured, is_active, sort_order
  )
  select v_new_id, block_count, title, description, badge, is_featured, is_active, sort_order
  from public.service_duration_presets where service_id = p_service_id;

  insert into public.service_duration_guidance_ranges (
    service_id, min_blocks, max_blocks, title, description, is_active, sort_order
  )
  select v_new_id, min_blocks, max_blocks, title, description, is_active, sort_order
  from public.service_duration_guidance_ranges where service_id = p_service_id;

  insert into public.service_fields (
    service_id, field_key, label, field_type, help_text, placeholder,
    is_required, sort_order, options_json, is_active
  )
  select v_new_id, field_key, label, field_type, help_text, placeholder,
    is_required, sort_order, options_json, is_active
  from public.service_fields where service_id = p_service_id;

  insert into public.service_extras (
    service_id, extra_id, sort_order, is_required, max_quantity,
    schedule_placement, default_schedule_minutes, schedule_updated_at
  )
  select v_new_id, extra_id, sort_order, is_required, max_quantity,
    schedule_placement, default_schedule_minutes, schedule_updated_at
  from public.service_extras where service_id = p_service_id;

  insert into public.service_extra_schedule_rules (
    service_id, extra_id, days_of_week, anchor_start_local_time, anchor_end_local_time,
    schedule_placement, schedule_minutes, priority, is_active
  )
  select v_new_id, extra_id, days_of_week, anchor_start_local_time, anchor_end_local_time,
    schedule_placement, schedule_minutes, priority, is_active
  from public.service_extra_schedule_rules where service_id = p_service_id;

  insert into public.service_resources (service_id, resource_id, is_required)
  select v_new_id, resource_id, is_required
  from public.service_resources where service_id = p_service_id;

  for v_old_service_employee in
    select * from public.service_employees where service_id = p_service_id
  loop
    insert into public.service_employees (service_id, employee_id, is_active)
    values (v_new_id, v_old_service_employee.employee_id, v_old_service_employee.is_active)
    returning id into v_new_service_employee_id;

    insert into public.service_employee_calendar_write (
      service_employee_id, google_calendar_id, time_scope
    )
    select v_new_service_employee_id, google_calendar_id, time_scope
    from public.service_employee_calendar_write
    where service_employee_id = v_old_service_employee.id;
  end loop;

  insert into public.terms_versions (
    service_id, name, version, content, is_active, published_at
  )
  select v_new_id, name, version, content, is_active, published_at
  from public.terms_versions where service_id = p_service_id;

  insert into public.notification_template_services (template_id, service_id)
  select template_id, v_new_id
  from public.notification_template_services where service_id = p_service_id;

  insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
  select booking_page_id, v_new_id, sort_order, false
  from public.booking_page_services where service_id = p_service_id;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id,
    'SERVICE',
    v_new_id,
    'SERVICE_DUPLICATED',
    jsonb_build_object('source_service_id', p_service_id, 'source_name', v_source.name, 'source_slug', v_source.slug),
    jsonb_build_object(
      'service', (select to_jsonb(s) from public.services s where s.id = v_new_id),
      'source_service_id', p_service_id,
      'starts_inactive', true
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'service', (select to_jsonb(s) from public.services s where s.id = v_new_id),
    'source_service_id', p_service_id,
    'starts_inactive', true
  );
end;
$function$;
