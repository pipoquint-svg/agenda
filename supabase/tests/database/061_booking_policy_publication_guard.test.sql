begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

insert into public.categories(id, name, slug)
values ('96200000-0000-0000-0000-000000000001', 'Policy Publication Guard', 'policy-publication-guard');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values
  ('96200000-0000-0000-0000-000000000002', '96200000-0000-0000-0000-000000000001',
   'Sem Política', 'sem-politica-publicacao', 60, 100, 1, 3, 365),
  ('96200000-0000-0000-0000-000000000003', '96200000-0000-0000-0000-000000000001',
   'Com Política', 'com-politica-publicacao', 60, 100, 1, 3, 365);

insert into public.service_change_policies(
  service_id, notice_hours,
  reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values (
  '96200000-0000-0000-0000-000000000003', 48, 0, 20, 20, 20
);

select throws_ok(
  $$
    insert into public.booking_page_services(booking_page_id, service_id, sort_order, is_active)
    select id, '96200000-0000-0000-0000-000000000002', 10, true
    from public.booking_pages where slug = 'sabrina'
  $$,
  'P0001',
  'SERVICE_CHANGE_POLICY_REQUIRED_FOR_PUBLIC_BOOKING',
  'service without policy cannot be activated on an active booking page'
);

select lives_ok(
  $$
    insert into public.booking_page_services(booking_page_id, service_id, sort_order, is_active)
    select id, '96200000-0000-0000-0000-000000000003', 20, true
    from public.booking_pages where slug = 'sabrina'
  $$,
  'service with policy can be activated on an active booking page'
);

select throws_ok(
  $$ delete from public.service_change_policies where service_id = '96200000-0000-0000-0000-000000000003' $$,
  'P0001',
  'PUBLIC_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED',
  'policy cannot be deleted while service remains publicly bookable'
);

update public.booking_page_services
set is_active = false
where service_id = '96200000-0000-0000-0000-000000000003';

select lives_ok(
  $$ delete from public.service_change_policies where service_id = '96200000-0000-0000-0000-000000000003' $$,
  'policy may be removed only after public linkage is disabled'
);

select lives_ok(
  $$
    insert into public.booking_pages(id, slug, display_name, title, brand_key, is_active)
    values ('96200000-0000-0000-0000-000000000004', 'policy-draft-page', 'Policy Draft', 'Policy Draft', 'TEST', false)
  $$,
  'inactive booking page may exist while configuration is incomplete'
);

select lives_ok(
  $$
    insert into public.booking_page_services(booking_page_id, service_id, sort_order, is_active)
    values ('96200000-0000-0000-0000-000000000004', '96200000-0000-0000-0000-000000000002', 10, true)
  $$,
  'draft page may stage an active service link before publication'
);

select throws_ok(
  $$ update public.booking_pages set is_active = true where id = '96200000-0000-0000-0000-000000000004' $$,
  'P0001',
  'BOOKING_PAGE_HAS_SERVICE_WITHOUT_CHANGE_POLICY',
  'draft page cannot be published while an active linked service lacks policy'
);

select is(
  (
    select count(*)::integer
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    left join public.service_change_policies cp on cp.service_id = bps.service_id
    where bp.is_active and bps.is_active and cp.service_id is null
  ),
  0,
  'database invariant leaves no active public service without policy'
);

select * from finish();
rollback;
