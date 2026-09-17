do $$
declare
  v_service_id uuid;
  v_page_id uuid;
  v_source_service_id uuid;
  v_source_service_employee_id uuid;
  v_employee_id uuid;
  v_visit_service_employee_id uuid;
begin
  select s.id into v_source_service_id
  from public.services s
  where s.slug='locacao-estudio' and s.is_active
  limit 1;

  -- BlackSheep catalog data is production-specific. A clean schema rebuild must
  -- remain valid even when that operational seed is not present.
  if v_source_service_id is null then
    raise notice 'SOURCE_BLACKSHEEP_RENTAL_SERVICE_NOT_FOUND: skipping BlackSheep free-visit seed';
    return;
  end if;

  insert into public.services (
    category_id,name,slug,short_description,full_description,cover_image_url,
    base_duration_minutes,buffer_before_minutes,buffer_after_minutes,base_price,
    minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days,
    confirmation_percentage,checkout_hold_minutes,payment_hold_minutes,
    allow_reschedule,reschedule_min_notice_minutes,max_reschedules,
    allow_cancel,cancel_min_notice_minutes,requires_terms,is_active,sort_order,
    duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,
    operation_scope,booking_product_type,price_per_extra_person,service_type_id,
    checkout_minimum_payment_type,checkout_minimum_payment_value,slot_interval_minutes,
    public_minimum_booking_notice_hours,pix_discount_percent,payment_mode,card_max_installments,included_people
  )
  select
    src.category_id,
    'Conhecer o estúdio sem compromisso',
    'visita-estudio',
    'Visita gratuita de 30 minutos para conhecer o BlackSheep Estúdio Criativo.',
    'Agende 30 minutos para conhecer o estúdio, tirar dúvidas e avaliar o espaço antes de reservar. Sem custo e sem compromisso.',
    src.cover_image_url,
    30,0,0,0,
    1,1,src.minimum_booking_notice_minutes,src.maximum_booking_horizon_days,
    null,src.checkout_hold_minutes,src.payment_hold_minutes,
    src.allow_reschedule,src.reschedule_min_notice_minutes,src.max_reschedules,
    true,0,false,true,5,
    'FIXED',null,null,null,null,
    'BLACKSHEEP','FREE_VISIT',0,src.service_type_id,
    'FIXED',0,30,src.public_minimum_booking_notice_hours,null,'FULL_ONLY',1,1
  from public.services src
  where src.id=v_source_service_id
  on conflict (slug) do update set
    category_id=excluded.category_id,
    name=excluded.name,
    short_description=excluded.short_description,
    full_description=excluded.full_description,
    cover_image_url=excluded.cover_image_url,
    base_duration_minutes=30,
    buffer_before_minutes=0,
    buffer_after_minutes=0,
    base_price=0,
    minimum_people=1,
    maximum_people=1,
    confirmation_percentage=null,
    allow_cancel=true,
    cancel_min_notice_minutes=0,
    requires_terms=false,
    is_active=true,
    sort_order=5,
    duration_mode='FIXED',
    booking_block_minutes=null,
    minimum_booking_blocks=null,
    maximum_booking_blocks=null,
    price_per_block=null,
    operation_scope='BLACKSHEEP',
    booking_product_type='FREE_VISIT',
    price_per_extra_person=0,
    service_type_id=excluded.service_type_id,
    checkout_minimum_payment_type='FIXED',
    checkout_minimum_payment_value=0,
    slot_interval_minutes=30,
    public_minimum_booking_notice_hours=excluded.public_minimum_booking_notice_hours,
    pix_discount_percent=null,
    payment_mode='FULL_ONLY',
    card_max_installments=1,
    included_people=1,
    updated_at=now()
  returning id into v_service_id;

  insert into public.service_change_policies (
    service_id,notice_hours,
    reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent,
    reschedule_first_early_penalty_type,reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type,reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
    cancellation_late_penalty_type,cancellation_late_penalty_value
  )
  select
    v_service_id,scp.notice_hours,
    scp.reschedule_first_early_percent,scp.reschedule_first_late_percent,scp.reschedule_repeat_percent,scp.cancellation_late_percent,
    scp.reschedule_first_early_penalty_type,scp.reschedule_first_early_penalty_value,
    scp.reschedule_first_late_penalty_type,scp.reschedule_first_late_penalty_value,
    scp.reschedule_repeat_penalty_type,scp.reschedule_repeat_penalty_value,
    scp.cancellation_late_penalty_type,scp.cancellation_late_penalty_value
  from public.service_change_policies scp
  where scp.service_id=v_source_service_id
  on conflict (service_id) do update set
    notice_hours=excluded.notice_hours,
    reschedule_first_early_percent=excluded.reschedule_first_early_percent,
    reschedule_first_late_percent=excluded.reschedule_first_late_percent,
    reschedule_repeat_percent=excluded.reschedule_repeat_percent,
    cancellation_late_percent=excluded.cancellation_late_percent,
    reschedule_first_early_penalty_type=excluded.reschedule_first_early_penalty_type,
    reschedule_first_early_penalty_value=excluded.reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type=excluded.reschedule_first_late_penalty_type,
    reschedule_first_late_penalty_value=excluded.reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type=excluded.reschedule_repeat_penalty_type,
    reschedule_repeat_penalty_value=excluded.reschedule_repeat_penalty_value,
    cancellation_late_penalty_type=excluded.cancellation_late_penalty_type,
    cancellation_late_penalty_value=excluded.cancellation_late_penalty_value,
    updated_at=now();

  insert into public.booking_pages (
    slug,display_name,title,subtitle,brand_key,logo_url,accent_color,is_active,sort_order,require_tax_id,payment_provider
  ) values (
    'blacksheep-visita','BlackSheep Estúdio Criativo','Conhecer o estúdio sem compromisso',
    'Agende uma visita gratuita de 30 minutos para conhecer o espaço.','BLACKSHEEP',null,null,true,21,false,'MERCADO_PAGO'
  )
  on conflict (slug) do update set
    display_name=excluded.display_name,
    title=excluded.title,
    subtitle=excluded.subtitle,
    brand_key='BLACKSHEEP',
    is_active=true,
    require_tax_id=false,
    payment_provider='MERCADO_PAGO',
    updated_at=now()
  returning id into v_page_id;

  insert into public.booking_page_services (booking_page_id,service_id,sort_order,is_active)
  values (v_page_id,v_service_id,10,true)
  on conflict (booking_page_id,service_id) do update set sort_order=10,is_active=true;

  select se.id,se.employee_id
  into v_source_service_employee_id,v_employee_id
  from public.service_employees se
  where se.service_id=v_source_service_id and se.is_active
  order by se.created_at
  limit 1;

  if v_source_service_employee_id is null or v_employee_id is null then
    raise notice 'SOURCE_BLACKSHEEP_SERVICE_EMPLOYEE_NOT_FOUND: free-visit service created without employee mapping';
    return;
  end if;

  insert into public.service_employees (service_id,employee_id,is_active)
  values (v_service_id,v_employee_id,true)
  on conflict (service_id,employee_id) do update set is_active=true
  returning id into v_visit_service_employee_id;

  insert into public.service_resources (service_id,resource_id,is_required)
  select v_service_id,sr.resource_id,sr.is_required
  from public.service_resources sr
  where sr.service_id=v_source_service_id
  on conflict (service_id,resource_id) do update set is_required=excluded.is_required;

  insert into public.availability_rules (
    service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active
  )
  select v_visit_service_employee_id,ar.weekday,ar.start_local_time,ar.end_local_time,ar.slot_interval_minutes,ar.is_active
  from public.availability_rules ar
  where ar.service_employee_id=v_source_service_employee_id
  on conflict (service_employee_id,weekday,start_local_time,end_local_time)
  do update set slot_interval_minutes=excluded.slot_interval_minutes,is_active=excluded.is_active,updated_at=now();

  insert into public.service_employee_calendar_write (service_employee_id,google_calendar_id,time_scope)
  select v_visit_service_employee_id,secw.google_calendar_id,secw.time_scope
  from public.service_employee_calendar_write secw
  where secw.service_employee_id=v_source_service_employee_id
  on conflict (service_employee_id) do update set
    google_calendar_id=excluded.google_calendar_id,
    time_scope=excluded.time_scope,
    updated_at=now();

  insert into public.availability_exceptions (
    service_employee_id,resource_id,exception_type,start_at,end_at,reason,special_calendar_date_id
  )
  select
    v_visit_service_employee_id,ae.resource_id,ae.exception_type,ae.start_at,ae.end_at,ae.reason,ae.special_calendar_date_id
  from public.availability_exceptions ae
  where ae.service_employee_id=v_source_service_employee_id
    and ae.end_at>=now()
    and not exists (
      select 1
      from public.availability_exceptions existing
      where existing.service_employee_id=v_visit_service_employee_id
        and existing.exception_type=ae.exception_type
        and existing.start_at=ae.start_at
        and existing.end_at=ae.end_at
        and existing.resource_id is not distinct from ae.resource_id
        and existing.reason is not distinct from ae.reason
        and existing.special_calendar_date_id is not distinct from ae.special_calendar_date_id
    );
end $$;
