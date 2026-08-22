begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(35);

select has_table('public', 'pre_reservation_access_tokens', 'opaque pre-reservation access tokens exist');
select has_column('public', 'resource_allocations', 'pre_reservation_id', 'resource allocation can belong to a pre-reservation');
select has_column('public', 'appointments', 'invoice_due_basis', 'appointment stores invoice due basis');
select has_column('public', 'appointments', 'invoice_due_base_at', 'appointment stores exact invoice due base timestamp');
select has_column('public', 'appointments', 'invoice_due_days_snapshot', 'appointment snapshots invoice due days');
select has_function('public', 'service_admin_create_pre_reservation', array['uuid','uuid','uuid','timestamp with time zone','uuid','integer','jsonb','integer','text'], 'authoritative pre-reservation creator exists');
select has_function('public', 'service_admin_confirm_pre_reservation', array['uuid','uuid'], 'atomic pre-reservation confirmation exists');
select has_function('public', 'service_admin_cancel_pre_reservation', array['uuid','uuid','text'], 'audited pre-reservation cancellation exists');
select has_function('public', 'public_get_pre_reservation_context', array['text'], 'opaque public pre-reservation context exists');
select ok(not has_table_privilege('service_role','public.pre_reservations','INSERT'), 'service_role cannot bypass pre-reservation creator with direct insert');
select ok(not has_table_privilege('service_role','public.pre_reservations','UPDATE'), 'service_role cannot bypass audited pre-reservation mutation with direct update');

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('14400000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-prebook@example.test', '', now(), now()),
  ('14400000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-prebook@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('24400000-0000-4000-8000-000000000001', '14400000-0000-4000-8000-000000000001', 'Owner Prebook Test', 'OWNER'),
  ('24400000-0000-4000-8000-000000000002', '14400000-0000-4000-8000-000000000002', 'Operation Prebook Test', 'OPERATION');

insert into public.categories(id, name, slug)
values ('94400000-0000-0000-0000-000000000001', 'Prebook Test', 'prebook-test');

insert into public.resources(id, name, resource_type)
values
  ('94400000-0000-0000-0000-000000000002', 'PREBOOK TEST STUDIO', 'PHYSICAL'),
  ('94400000-0000-0000-0000-000000000003', 'PREBOOK TEST PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values ('94400000-0000-0000-0000-000000000004', 'Prebook Test Employee', '94400000-0000-0000-0000-000000000003');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values
(
  '94400000-0000-0000-0000-000000000005',
  '94400000-0000-0000-0000-000000000001',
  'Locação Prebook Test', 'locacao-prebook-test',
  30, 90.00,
  0, 30,
  1, 20, 5000,
  'BLOCKS', 30, 2, 12, 90.00
),
(
  '94400000-0000-0000-0000-000000000015',
  '94400000-0000-0000-0000-000000000001',
  'Serviço Não Autorizado Prebook Test', 'nao-autorizado-prebook-test',
  60, 150.00,
  0, 0,
  1, 5, 5000,
  'FIXED', null, null, null, null
);

insert into public.service_employees(id, service_id, employee_id)
values
  ('94400000-0000-0000-0000-000000000006', '94400000-0000-0000-0000-000000000005', '94400000-0000-0000-0000-000000000004'),
  ('94400000-0000-0000-0000-000000000016', '94400000-0000-0000-0000-000000000015', '94400000-0000-0000-0000-000000000004');

insert into public.service_resources(service_id, resource_id, is_required)
values
  ('94400000-0000-0000-0000-000000000005', '94400000-0000-0000-0000-000000000002', true),
  ('94400000-0000-0000-0000-000000000015', '94400000-0000-0000-0000-000000000002', true);

-- 2030-01-01 is Tuesday. Service ends by 18:00 and the physical resource keeps
-- another 30 minutes available for the single service-level buffer.
insert into public.availability_rules(service_employee_id, weekday, start_local_time, end_local_time)
values
  ('94400000-0000-0000-0000-000000000006', 2, '08:00', '18:00'),
  ('94400000-0000-0000-0000-000000000016', 2, '08:00', '18:00');

insert into public.resource_availability_rules(resource_id, weekday, start_local_time, end_local_time)
values ('94400000-0000-0000-0000-000000000002', 2, '08:00', '18:30');

insert into public.customers(id, customer_type, name, email, phone)
values ('94400000-0000-0000-0000-000000000007', 'BUSINESS', 'Corporate Prebook Test', 'billing@example.test', '+5548999999999');

insert into public.customer_commercial_terms(
  customer_id, can_prebook, prebook_hold_minutes, max_active_prebooks,
  requires_manual_confirmation, billing_mode, invoice_due_days, is_active
) values (
  '94400000-0000-0000-0000-000000000007', true, 720, 1,
  true, 'INVOICE', 15, true
);

insert into public.customer_prebook_authorized_services(customer_id, service_id)
values ('94400000-0000-0000-0000-000000000007', '94400000-0000-0000-0000-000000000005');

select throws_ok(
  $$select public.service_admin_create_pre_reservation(
    '94400000-0000-0000-0000-000000000007',
    '94400000-0000-0000-0000-000000000015',
    '94400000-0000-0000-0000-000000000016',
    '2030-01-01 08:00:00-03'::timestamptz,
    '24400000-0000-4000-8000-000000000001',
    null, '[]'::jsonb, 1, null
  )$$,
  'P0001', 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK',
  'service allowlist is enforced by the backend'
);

create temporary table prebook_created as
select public.service_admin_create_pre_reservation(
  '94400000-0000-0000-0000-000000000007',
  '94400000-0000-0000-0000-000000000005',
  '94400000-0000-0000-0000-000000000006',
  '2030-01-01 08:00:00-03'::timestamptz,
  '24400000-0000-4000-8000-000000000001',
  4, '[]'::jsonb, 1, 'authoritative prebook test'
) payload;

select is(
  (select payload->>'authoritative_resource_hold' from prebook_created),
  'true',
  'pre-reservation is explicitly reported as an authoritative resource hold'
);

select is(
  (select count(*)::integer
   from public.resource_allocations ra
   where ra.pre_reservation_id = (select (payload->>'pre_reservation_id')::uuid from prebook_created)
     and ra.allocation_type = 'PRE_RESERVATION'
     and ra.status = 'HELD'),
  1,
  'pre-reservation owns a blocking allocation in the shared resource ledger'
);

create temporary table prebook_allocation_before as
select ra.id
from public.resource_allocations ra
where ra.pre_reservation_id = (select (payload->>'pre_reservation_id')::uuid from prebook_created)
  and ra.status = 'HELD';

select throws_ok(
  $$select public.create_checkout_hold_for_duration(
    '94400000-0000-0000-0000-000000000005',
    '94400000-0000-0000-0000-000000000006',
    4, '[]'::jsonb, 1,
    '2030-01-01 08:00:00-03'::timestamptz
  )$$,
  'P0001', 'SLOT_NO_LONGER_AVAILABLE',
  'normal checkout hold cannot enter a slot protected by a pre-reservation'
);

select throws_ok(
  $$select public.service_admin_create_pre_reservation(
    '94400000-0000-0000-0000-000000000007',
    '94400000-0000-0000-0000-000000000005',
    '94400000-0000-0000-0000-000000000006',
    '2030-01-01 11:00:00-03'::timestamptz,
    '24400000-0000-4000-8000-000000000001',
    4, '[]'::jsonb, 1, null
  )$$,
  'P0001', 'MAX_ACTIVE_PREBOOKS_REACHED',
  'max_active_prebooks is enforced by the backend'
);

select is(
  (public.public_get_pre_reservation_context(
    (select payload->>'access_token' from prebook_created)
  )->>'authoritative_resource_hold'),
  'true',
  'opaque token resolves the protected pre-reservation context'
);

select ok(
  not (public.public_get_pre_reservation_context(
    (select payload->>'access_token' from prebook_created)
  ) ?| array['customer_id','email','phone','cpf_cnpj']),
  'public pre-reservation context does not expose customer PII'
);

select ok(
  (select token_hash <> (select payload->>'access_token' from prebook_created)
   from public.pre_reservation_access_tokens
   where pre_reservation_id = (select (payload->>'pre_reservation_id')::uuid from prebook_created)),
  'raw opaque token is never stored in the database'
);

select throws_ok(
  $$select public.service_admin_confirm_pre_reservation(
    (select (payload->>'pre_reservation_id')::uuid from prebook_created),
    '24400000-0000-4000-8000-000000000002'
  )$$,
  'P0001', 'ADMIN_PERMISSION_DENIED',
  'operation role cannot authorize an INVOICE pre-reservation without FINANCE_MANAGE'
);

create temporary table prebook_confirmed as
select public.service_admin_confirm_pre_reservation(
  (select (payload->>'pre_reservation_id')::uuid from prebook_created),
  '24400000-0000-4000-8000-000000000001'
) payload;

select is(
  (select a.status::text
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  'CONFIRMED',
  'INVOICE pre-reservation confirms directly without Mercado Pago checkout'
);

select is(
  (select a.financial_status::text
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  'UNPAID_AUTHORIZED',
  'confirmed INVOICE appointment is explicitly receivable/unpaid-authorized'
);

select is(
  (select a.billing_mode_snapshot
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  'INVOICE',
  'appointment snapshots INVOICE billing mode'
);

select is(
  (select a.invoice_due_basis
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  'SERVICE_START',
  'invoice due basis is explicitly SERVICE_START'
);

select is(
  (select a.invoice_due_base_at
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  '2030-01-01 08:00:00-03'::timestamptz,
  'invoice due base timestamp is the service start'
);

select is(
  (select a.invoice_due_days_snapshot
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  15,
  'invoice due days are snapshotted from customer terms'
);

select is(
  (select a.invoice_due_at
   from public.appointments a
   where a.id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  '2030-01-16 08:00:00-03'::timestamptz,
  'invoice due date equals service start plus 15 days exactly'
);

select is(
  (select ra.id from public.resource_allocations ra
   where ra.appointment_id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  (select id from prebook_allocation_before),
  'confirmation transfers the exact same allocation row instead of release/recreate'
);

select is(
  (select ra.allocation_type::text || ':' || ra.status::text
   from public.resource_allocations ra
   where ra.appointment_id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  'APPOINTMENT:CONFIRMED',
  'transferred allocation becomes a confirmed appointment allocation atomically'
);

select is(
  (select count(*)::integer
   from public.payment_transactions pt
   where pt.appointment_id = (select (payload->>'appointment_id')::uuid from prebook_confirmed)),
  0,
  'INVOICE confirmation creates no Mercado Pago/payment transaction'
);

select throws_ok(
  $$select public.public_get_pre_reservation_context(
    (select payload->>'access_token' from prebook_created)
  )$$,
  'P0001', 'PRE_RESERVATION_TOKEN_INVALID',
  'pre-reservation token is revoked when it converts to an appointment'
);

select is(
  (select count(*)::integer from public.audit_logs
   where entity_type = 'PRE_RESERVATION'
     and entity_id = (select (payload->>'pre_reservation_id')::uuid from prebook_created)
     and action in ('PRE_RESERVATION_CREATED','PRE_RESERVATION_CONFIRMED')),
  2,
  'creation and confirmation are both audited'
);

-- Expiration releases the resource and records a system release.
create temporary table prebook_expiring as
select public.service_admin_create_pre_reservation(
  '94400000-0000-0000-0000-000000000007',
  '94400000-0000-0000-0000-000000000005',
  '94400000-0000-0000-0000-000000000006',
  '2030-01-01 11:00:00-03'::timestamptz,
  '24400000-0000-4000-8000-000000000001',
  4, '[]'::jsonb, 1, null
) payload;

update public.pre_reservations
set created_at = now() - interval '2 hours',
    expires_at = now() - interval '1 hour'
where id = (select (payload->>'pre_reservation_id')::uuid from prebook_expiring);

select is(public.service_expire_pre_reservations(), 1, 'expiration worker expires exactly the due pre-reservation');
select is(
  (select status from public.pre_reservations
   where id = (select (payload->>'pre_reservation_id')::uuid from prebook_expiring)),
  'EXPIRED',
  'expired pre-reservation leaves ACTIVE state'
);
select is(
  (select status::text from public.resource_allocations
   where pre_reservation_id = (select (payload->>'pre_reservation_id')::uuid from prebook_expiring)),
  'EXPIRED',
  'expiration releases the blocking allocation'
);
select ok(
  (select released_at is not null and released_by_admin_id is null and release_reason = 'EXPIRED'
   from public.pre_reservations
   where id = (select (payload->>'pre_reservation_id')::uuid from prebook_expiring)),
  'system expiration records release date and system actor semantics'
);

-- Manual cancellation records the actor and also releases the allocation.
create temporary table prebook_cancelled as
select public.service_admin_create_pre_reservation(
  '94400000-0000-0000-0000-000000000007',
  '94400000-0000-0000-0000-000000000005',
  '94400000-0000-0000-0000-000000000006',
  '2030-01-01 14:00:00-03'::timestamptz,
  '24400000-0000-4000-8000-000000000001',
  4, '[]'::jsonb, 1, null
) payload;

select lives_ok(
  $$select public.service_admin_cancel_pre_reservation(
    (select (payload->>'pre_reservation_id')::uuid from prebook_cancelled),
    '24400000-0000-4000-8000-000000000001',
    'client requested release'
  )$$,
  'authorized admin can cancel and release a pre-reservation'
);

select ok(
  (select status = 'CANCELLED'
      and released_at is not null
      and released_by_admin_id = '24400000-0000-4000-8000-000000000001'::uuid
      and release_reason = 'client requested release'
   from public.pre_reservations
   where id = (select (payload->>'pre_reservation_id')::uuid from prebook_cancelled)),
  'manual cancellation records status, actor, timestamp and reason'
);

select is(
  (select status::text from public.resource_allocations
   where pre_reservation_id = (select (payload->>'pre_reservation_id')::uuid from prebook_cancelled)),
  'CANCELLED',
  'manual cancellation releases the allocation in the shared ledger'
);

select * from finish();
rollback;
