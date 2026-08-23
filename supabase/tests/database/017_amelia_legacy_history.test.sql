begin;

select plan(17);

select has_table('public', 'legacy_amelia_import_batches', 'legacy Amelia import batches exist');
select has_table('public', 'legacy_amelia_bookings', 'legacy Amelia history table exists');

select ok(
  not has_table_privilege('authenticated', 'public.legacy_amelia_bookings', 'SELECT'),
  'authenticated role cannot select legacy bookings directly; admin access is Edge/backend only'
);

select ok(
  not has_table_privilege('authenticated', 'public.legacy_amelia_bookings', 'INSERT'),
  'authenticated role cannot insert legacy bookings directly'
);

select ok(
  not has_table_privilege('authenticated', 'public.legacy_amelia_bookings', 'UPDATE'),
  'authenticated role cannot update legacy bookings directly'
);

select ok(
  not has_table_privilege('authenticated', 'public.legacy_amelia_bookings', 'DELETE'),
  'authenticated role cannot delete legacy bookings directly'
);

create temporary table legacy_baseline_counts as
select
  (select count(*) from public.appointments) as appointments_count,
  (select count(*) from public.resource_allocations) as allocations_count,
  (select count(*) from public.payment_transactions) as payments_count,
  (select count(*) from public.integration_jobs) as jobs_count;

create temporary table legacy_batch as
select public.create_legacy_amelia_import_batch(
  'amelia.csv',
  repeat('a', 64),
  1,
  'test batch',
  null
) as id;

create temporary table imported_legacy as
select public.upsert_legacy_amelia_booking(
  (select id from legacy_batch),
  jsonb_build_object(
    'amelia_booking_id', 'AM-1001',
    'woocommerce_order_id', 'WC-55',
    'customer_name', 'Cliente Legado',
    'customer_email', 'CLIENTE@EXAMPLE.COM',
    'customer_phone', '48999999999',
    'service_name', 'Ensaio Gestante',
    'employee_name', 'Sabrina',
    'start_at', '2026-09-10T09:00:00-03:00',
    'end_at', '2026-09-10T10:30:00-03:00',
    'declared_duration_minutes', 60,
    'status_raw', 'approved',
    'amelia_price_amount', '100.00',
    'extras', jsonb_build_array(jsonb_build_object('name','Maquiagem')),
    'custom_fields', jsonb_build_object('gestante_semanas', 30)
  )
) as id;

select is(
  (select count(*)::integer from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  1,
  'Amelia row is stored once in legacy history'
);

select is(
  (select operational_authority from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  'AMELIA',
  'Amelia remains the operational authority'
);

select is(
  (select record_mode from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  'HISTORY_ONLY',
  'legacy row is explicitly history-only'
);

select is(
  (select cpf_cnpj from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  null::text,
  'CPF remains null when source export does not contain it'
);

select is(
  (select customer_email from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  'cliente@example.com',
  'legacy email is normalized without creating a customer record'
);

select is(
  (select appointments_count from legacy_baseline_counts),
  (select count(*) from public.appointments),
  'legacy import creates no Agenda appointment'
);

select is(
  (select allocations_count from legacy_baseline_counts),
  (select count(*) from public.resource_allocations),
  'legacy import creates no resource allocation'
);

select is(
  (select payments_count from legacy_baseline_counts),
  (select count(*) from public.payment_transactions),
  'legacy import creates no payment transaction'
);

select is(
  (select jobs_count from legacy_baseline_counts),
  (select count(*) from public.integration_jobs),
  'legacy import creates no Google/message/outbox job'
);

select public.upsert_legacy_amelia_booking(
  (select id from legacy_batch),
  jsonb_build_object(
    'amelia_booking_id', 'AM-1001',
    'customer_name', 'Cliente Legado',
    'customer_email', 'cliente@example.com',
    'customer_phone', '48999999999',
    'service_name', 'Ensaio Gestante',
    'employee_name', 'Sabrina',
    'start_at', '2026-09-10T09:00:00-03:00',
    'end_at', '2026-09-10T10:30:00-03:00',
    'declared_duration_minutes', 60,
    'status_raw', 'cancelled',
    'amelia_price_amount', '100.00'
  )
);

select is(
  (select count(*)::integer from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  1,
  're-import updates snapshot instead of duplicating history row'
);

select is(
  (select import_revision from public.legacy_amelia_bookings where amelia_booking_id = 'AM-1001'),
  2,
  're-import increments legacy snapshot revision'
);

select * from finish();
rollback;
