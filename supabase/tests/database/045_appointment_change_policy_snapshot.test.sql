begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

insert into public.customers(id,name,email)
values ('45000000-0000-0000-0000-000000000001','Snapshot Customer','snapshot@example.com');

insert into public.employees(id,name)
values ('45000000-0000-0000-0000-000000000002','Snapshot Employee');

insert into public.categories(id,name,slug)
values ('45000000-0000-0000-0000-000000000003','Snapshot','snapshot-policy');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,requires_terms
) values (
  '45000000-0000-0000-0000-000000000004',
  '45000000-0000-0000-0000-000000000003',
  'Snapshot Service','snapshot-service',120,1000,1,10,true
);

insert into public.service_employees(id,service_id,employee_id)
values (
  '45000000-0000-0000-0000-000000000005',
  '45000000-0000-0000-0000-000000000004',
  '45000000-0000-0000-0000-000000000002'
);

insert into public.service_change_policies(
  service_id,notice_hours,
  reschedule_first_penalty_type,reschedule_first_penalty_value,
  reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
  reschedule_late_penalty_type,reschedule_late_penalty_value,
  cancellation_early_penalty_type,cancellation_early_penalty_value,
  cancellation_late_penalty_type,cancellation_late_penalty_value,
  cancellation_early_refund_allowed,cancellation_early_credit_allowed,
  cancellation_late_refund_allowed,cancellation_late_credit_allowed,
  cancellation_credit_validity_days
) values (
  '45000000-0000-0000-0000-000000000004',48,
  'NONE',0,
  'PERCENT',20,
  'PERCENT',20,
  'NONE',0,
  'PERCENT',20,
  true,true,true,true,90
);

insert into public.terms_versions(
  id,service_id,name,version,content,is_active,published_at
) values (
  '45000000-0000-0000-0000-000000000006',
  '45000000-0000-0000-0000-000000000004',
  'Política comercial','v1','Termos v1',true,now() - interval '1 day'
);

insert into public.appointments(
  id,public_code,service_id,service_employee_id,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,
  commercial_value,confirmed_at
) values (
  '45000000-0000-0000-0000-000000000007','SNAPSHOT-OLD',
  '45000000-0000-0000-0000-000000000004',
  '45000000-0000-0000-0000-000000000005',
  '45000000-0000-0000-0000-000000000001',
  'CONFIRMED','PARTIALLY_PAID',
  '2035-01-10 15:00:00-03','2035-01-10 17:00:00-03',120,1,1000,now()
);

insert into public.appointment_term_acceptances(
  appointment_id,terms_version_id,content_snapshot,accepted_at
) values (
  '45000000-0000-0000-0000-000000000007',
  '45000000-0000-0000-0000-000000000006',
  'Termos v1',now()
);

insert into public.payment_transactions(
  appointment_id,transaction_type,method,provider,provider_payment_id,
  status,contract_amount_settled,cash_amount,paid_at,payment_purpose
) values (
  '45000000-0000-0000-0000-000000000007',
  'CHARGE','PIX','MERCADO_PAGO','snapshot-payment-old',
  'APPROVED',500,500,now(),'CONTRACT'
);

select ok(
  exists(select 1 from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),
  'confirmed appointment receives a policy snapshot'
);

select is(
  (select (s.policy_json->>'reschedule_late_penalty_value')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),
  20.00::numeric,
  'snapshot freezes the policy value in force for the reservation'
);

select is(
  (select s.max_customer_reschedules::integer from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),
  3,
  'snapshot records the three client-reschedule limit explicitly'
);

select is(
  (select s.notice_boundary_semantics from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),
  'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
  'exact notice boundary semantics are explicit, not incidental'
);

select ok(
  exists(
    select 1 from public.appointment_change_policy_snapshot_terms st
    where st.appointment_id='45000000-0000-0000-0000-000000000007'
      and st.terms_version_id='45000000-0000-0000-0000-000000000006'
      and st.version_snapshot='v1'
  ),
  'snapshot records the terms version corresponding to the reservation'
);

-- Change the live service policy after the reservation. The old reservation must
-- continue using 20%, while a later reservation receives 35%.
update public.service_change_policies
set reschedule_late_penalty_value=35,
    cancellation_late_penalty_value=35,
    updated_at=now()+interval '1 second'
where service_id='45000000-0000-0000-0000-000000000004';

insert into public.terms_versions(
  id,service_id,name,version,content,is_active,published_at
) values (
  '45000000-0000-0000-0000-000000000008',
  '45000000-0000-0000-0000-000000000004',
  'Política comercial','v2','Termos v2',true,now()
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 14:59:59-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'one second before the 48h boundary is outside the penalty window for reschedule'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 15:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'exactly 48h before is outside the penalty window for reschedule'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 15:00:01-03'
  )->>'penalty_amount')::numeric,
  200.00::numeric,
  'one second after the 48h boundary uses the OLD reservation snapshot for reschedule'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 14:59:59-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'one second before the 48h boundary is outside the penalty window for cancellation'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 15:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'exactly 48h before is outside the penalty window for cancellation'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 15:00:01-03'
  )->>'penalty_amount')::numeric,
  200.00::numeric,
  'one second after the 48h boundary uses the OLD reservation snapshot for cancellation'
);

select is(
  (select (s.policy_json->>'cancellation_late_penalty_value')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),
  20.00::numeric,
  'live service policy change does not mutate the prior reservation snapshot'
);

select ok(
  not exists(
    select 1 from public.appointment_change_policy_snapshot_terms st
    where st.appointment_id='45000000-0000-0000-0000-000000000007'
      and st.terms_version_id='45000000-0000-0000-0000-000000000008'
  ),
  'later terms publication does not alter prior reservation terms snapshot'
);

insert into public.appointments(
  id,public_code,service_id,service_employee_id,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,
  commercial_value,confirmed_at
) values (
  '45000000-0000-0000-0000-000000000009','SNAPSHOT-NEW',
  '45000000-0000-0000-0000-000000000004',
  '45000000-0000-0000-0000-000000000005',
  '45000000-0000-0000-0000-000000000001',
  'CONFIRMED','PARTIALLY_PAID',
  '2035-02-10 15:00:00-03','2035-02-10 17:00:00-03',120,1,1000,now()+interval '2 seconds'
);

insert into public.payment_transactions(
  appointment_id,transaction_type,method,provider,provider_payment_id,
  status,contract_amount_settled,cash_amount,paid_at,payment_purpose
) values (
  '45000000-0000-0000-0000-000000000009',
  'CHARGE','PIX','MERCADO_PAGO','snapshot-payment-new',
  'APPROVED',500,500,now(),'CONTRACT'
);

select is(
  (select (s.policy_json->>'reschedule_late_penalty_value')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000009'),
  35.00::numeric,
  'later reservation receives the later live policy in its own snapshot'
);

select ok(
  exists(
    select 1 from public.appointment_change_policy_snapshot_terms st
    where st.appointment_id='45000000-0000-0000-0000-000000000009'
      and st.terms_version_id='45000000-0000-0000-0000-000000000008'
      and st.version_snapshot='v2'
  ),
  'later reservation receives the later terms version in its own snapshot'
);

select is(
  (public.calculate_appointment_change_policy(
    '45000000-0000-0000-0000-000000000009','RESCHEDULE','2035-02-08 15:00:01-03'
  )->>'penalty_amount')::numeric,
  350.00::numeric,
  'later reservation calculation uses its own 35 percent snapshot'
);

select throws_ok(
  $$update public.appointment_change_policy_snapshots set max_customer_reschedules=3 where appointment_id='45000000-0000-0000-0000-000000000007'$$,
  '42501',
  'APPOINTMENT_CHANGE_POLICY_SNAPSHOT_IMMUTABLE',
  'reservation policy snapshot rejects mutation at database level'
);

select ok(
  not has_table_privilege('service_role','public.appointment_change_policy_snapshots','UPDATE')
  and not has_table_privilege('service_role','public.appointment_change_policy_snapshots','DELETE')
  and not has_table_privilege('service_role','public.appointment_change_policy_snapshots','TRUNCATE'),
  'service_role has no destructive privileges on reservation policy snapshots'
);

select * from finish();
rollback;
