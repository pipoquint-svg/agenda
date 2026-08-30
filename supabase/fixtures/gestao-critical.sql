-- Disposable fixtures for BlackSheep /gestao critical-flow E2E tests.
-- This file is loaded only into the local Supabase stack created by the test runner.
-- It is not a migration and must never be applied to production.

insert into public.resources (id, name, resource_type, is_active)
values ('99000000-0000-0000-0000-000000000001', 'QA ESTÚDIO', 'PHYSICAL', true);

insert into public.employees (id, name, is_active, resource_id)
values ('99000000-0000-0000-0000-000000000002', 'QA Atendimento', true, null);

insert into public.categories (id, name, slug)
values ('99000000-0000-0000-0000-000000000003', 'QA Gestão', 'qa-gestao');

-- Create inactive first: production invariant requires an active service to already
-- have a change policy. The fixture follows that invariant instead of bypassing it.
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
  false, 'BLACKSHEEP',
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

update public.services
set is_active = true,
    updated_at = now()
where id = '99000000-0000-0000-0000-000000000010';

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

-- Test-only finance scenario. It creates preconditions only; every financial mutation
-- (receipts, correction, cancellation, refund and balance application) is performed by
-- Playwright through the same browser/Edge boundaries used by the Gestão UI.
create or replace function public.qa_seed_gestao_finance_e2e()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text := replace(gen_random_uuid()::text, '-', '');
  v_customer uuid := gen_random_uuid();
  v_pix uuid := gen_random_uuid();
  v_cash uuid := gen_random_uuid();
  v_refund uuid := gen_random_uuid();
  v_balance uuid := gen_random_uuid();
  v_early uuid := gen_random_uuid();
  v_late uuid := gen_random_uuid();
  v_pix_code text := 'QA-FIN-PIX-' || left(v_token, 8);
  v_cash_code text := 'QA-FIN-CASH-' || left(v_token, 8);
  v_refund_code text := 'QA-FIN-REF-' || left(v_token, 8);
  v_balance_code text := 'QA-FIN-SALDO-' || left(v_token, 8);
begin
  insert into public.customers(id, name, email, phone)
  values (v_customer, 'Cliente QA Financeiro ' || left(v_token, 8), 'qa-fin-' || left(v_token, 8) || '@example.test', '+554899' || left(v_token, 8));

  insert into public.appointments(
    id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,
    duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at
  ) values
    (v_pix,v_pix_code,'99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','CONFIRMED','NOT_STARTED','2035-11-05 10:00:00-03','2035-11-05 11:00:00-03',60,1,v_customer,500,now()),
    (v_cash,v_cash_code,'99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','CONFIRMED','NOT_STARTED','2035-11-06 10:00:00-03','2035-11-06 11:00:00-03',60,1,v_customer,200,now()),
    (v_refund,v_refund_code,'99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','CONFIRMED','PAID','2035-11-07 10:00:00-03','2035-11-07 11:00:00-03',60,1,v_customer,300,now()),
    (v_balance,v_balance_code,'99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','CONFIRMED','NOT_STARTED','2035-11-08 10:00:00-03','2035-11-08 11:00:00-03',60,1,v_customer,250,now());

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,paid_at,payment_purpose,notes
  ) values (
    v_refund,'CHARGE','PIX','MANUAL','APPROVED',300,300,'2035-10-15 10:00:00-03','CONTRACT','QA precondition for off-gateway refund'
  );

  insert into public.customer_balance_movements(
    id,customer_id,movement_type,direction,amount,choice_origin,ip_address,user_agent,request_id,idempotency_key,created_at,expires_at
  ) values
    (v_early,v_customer,'CREDIT_FROM_RETURN','CREDIT',100,'CLIENT_TOKEN','127.0.0.1','Gestão E2E','qa-balance-early-'||v_token,'qa-balance-early-'||v_token,now(),now()+interval '6 months'),
    (v_late,v_customer,'CREDIT_FROM_RETURN','CREDIT',200,'CLIENT_TOKEN','127.0.0.1','Gestão E2E','qa-balance-late-'||v_token,'qa-balance-late-'||v_token,now(),now()+interval '12 months');

  return jsonb_build_object(
    'month','2035-11',
    'customer_id',v_customer,
    'pix',jsonb_build_object('id',v_pix,'public_code',v_pix_code,'amount',500),
    'cash',jsonb_build_object('id',v_cash,'public_code',v_cash_code,'amount',200),
    'refund',jsonb_build_object('id',v_refund,'public_code',v_refund_code,'amount',300,'local_date','2035-11-07'),
    'balance',jsonb_build_object('id',v_balance,'public_code',v_balance_code,'amount',250,'local_date','2035-11-08'),
    'balance_available',300,
    'balance_expected_apply',250,
    'balance_expected_after',50
  );
end;
$$;


-- Test-only read probes. Sensitive finance tables stay unavailable through PostgREST;
-- the disposable E2E harness can assert authoritative persistence via service_role RPCs.
create or replace function public.qa_read_gestao_payment_transactions(p_appointment_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
  from (
    select
      id, appointment_id, transaction_type, method, provider, status,
      contract_amount_settled, cash_amount, parent_transaction_id, paid_at, notes, created_at
    from public.payment_transactions
    where appointment_id = any(p_appointment_ids)
  ) t;
$$;

revoke all on function public.qa_read_gestao_payment_transactions(uuid[]) from public, anon, authenticated;
grant execute on function public.qa_read_gestao_payment_transactions(uuid[]) to service_role;

create or replace function public.qa_read_gestao_balance_movements(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb)
  from (
    select
      id, direction, movement_type, amount, appointment_id,
      source_credit_movement_id, expires_at, created_at
    from public.customer_balance_movements
    where customer_id = p_customer_id
  ) m;
$$;

revoke all on function public.qa_read_gestao_balance_movements(uuid) from public, anon, authenticated;
grant execute on function public.qa_read_gestao_balance_movements(uuid) to service_role;
