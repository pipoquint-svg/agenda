-- Disposable fixtures for BlackSheep /gestao critical-flow E2E tests.
-- This file is loaded only into the local Supabase stack created by the test runner.
-- It is not a migration and must never be applied to production.

insert into public.resources (id, name, resource_type, is_active)
values ('99000000-0000-0000-0000-000000000001', 'QA ESTÚDIO', 'PHYSICAL', true);

insert into public.employees (id, name, is_active, resource_id)
values ('99000000-0000-0000-0000-000000000002', 'QA Atendimento', true, null);

insert into public.categories (id, name, slug)
values ('99000000-0000-0000-0000-000000000003', 'QA Gestão', 'qa-gestao');

insert into public.services (
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  minimum_people, maximum_people,
  maximum_booking_horizon_days,
  checkout_hold_minutes, payment_hold_minutes,
  allow_reschedule, allow_cancel, requires_terms,
  is_active, operation_scope,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks,
  price_per_block
) values (
  '99000000-0000-0000-0000-000000000010',
  '99000000-0000-0000-0000-000000000003',
  'QA Reserva Crítica', 'qa-reserva-critica',
  60, 0,
  1, 4,
  5000,
  30, 1440,
  true, true, false,
  true, 'BLACKSHEEP',
  'BLOCKS', 30,
  2, 8,
  0
);

-- Zero-penalty test policy keeps the reschedule/cancel E2E focused on the workflow,
-- not on payment handling. Production policies are never read by this fixture.
insert into public.service_change_policies (
  service_id,
  notice_hours,
  reschedule_first_early_percent,
  reschedule_first_late_percent,
  reschedule_repeat_percent,
  cancellation_late_percent
) values (
  '99000000-0000-0000-0000-000000000010',
  0, 0, 0, 0, 0
);

insert into public.service_employees (id, service_id, employee_id, is_active)
values (
  '99000000-0000-0000-0000-000000000020',
  '99000000-0000-0000-0000-000000000010',
  '99000000-0000-0000-0000-000000000002',
  true
);

insert into public.service_resources (service_id, resource_id, is_required)
values (
  '99000000-0000-0000-0000-000000000010',
  '99000000-0000-0000-0000-000000000001',
  true
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes, is_active
)
select
  '99000000-0000-0000-0000-000000000020'::uuid,
  weekday,
  '08:00'::time,
  '20:00'::time,
  30,
  true
from generate_series(0, 6) weekday;

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time, is_active
)
select
  '99000000-0000-0000-0000-000000000001'::uuid,
  weekday,
  '08:00'::time,
  '20:00'::time,
  true
from generate_series(0, 6) weekday;

insert into public.customers (id, name, email, phone)
values
  ('99000000-0000-0000-0000-000000000050', 'Cliente QA Gestão', 'cliente.qa.gestao@example.test', '+5548999999001'),
  ('99000000-0000-0000-0000-000000000051', 'Cliente Busca Secundário', 'cliente.busca@example.test', '+5548999999002');

-- Test-only helper: builds a reservation through the same authoritative promotion
-- function used by checkout, then returns the actual appointment id/public code.
create or replace function public.qa_create_gestao_appointment(p_start_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold_id uuid := gen_random_uuid();
  v_end_at timestamptz := p_start_at + interval '60 minutes';
  v_result jsonb;
begin
  insert into public.checkout_holds (
    id, public_token_hash, service_id, service_employee_id, selection_hash,
    people_count, requested_start_at, requested_end_at, expires_at,
    extra_selections, commercial_value, pricing_version, duration_minutes,
    resource_ids, primary_customer_id, core_start_at, core_end_at,
    pre_service_minutes, post_service_minutes, schedule_profile,
    duration_blocks, contracted_minutes
  ) values (
    v_hold_id,
    'qa-' || replace(v_hold_id::text, '-', ''),
    '99000000-0000-0000-0000-000000000010',
    '99000000-0000-0000-0000-000000000020',
    'qa-selection-' || replace(v_hold_id::text, '-', ''),
    1, p_start_at, v_end_at, now() + interval '30 minutes',
    '[]'::jsonb, 0, 'qa-e2e', 60,
    array['99000000-0000-0000-0000-000000000001'::uuid],
    '99000000-0000-0000-0000-000000000050',
    p_start_at, v_end_at, 0, 0, '{}'::jsonb,
    2, 60
  );

  insert into public.resource_allocations (
    resource_id, checkout_hold_id, allocation_type, status, occupied_range
  ) values (
    '99000000-0000-0000-0000-000000000001',
    v_hold_id,
    'CHECKOUT_HOLD',
    'HELD',
    tstzrange(p_start_at, v_end_at, '[)')
  );

  v_result := public.promote_checkout_hold(
    v_hold_id,
    '99000000-0000-0000-0000-000000000050',
    null,
    '{}'::uuid[],
    '[]'::jsonb,
    '[]'::jsonb,
    '127.0.0.1'::inet,
    'BlackSheep Gestao E2E'
  );

  if coalesce(v_result->>'status', '') <> 'CONFIRMED' then
    raise exception 'QA_APPOINTMENT_NOT_CONFIRMED: %', v_result;
  end if;

  return v_result;
end;
$$;
