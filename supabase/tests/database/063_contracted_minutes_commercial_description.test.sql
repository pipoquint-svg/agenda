begin;

create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(12);

insert into public.categories(id,name,slug)
values ('96400000-0000-0000-0000-000000000001','Commercial Duration','commercial-duration');

insert into public.employees(id,name)
values ('96400000-0000-0000-0000-000000000002','Commercial Duration Employee');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,
  duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,
  confirmation_percentage,max_reschedules
) values
(
  '96400000-0000-0000-0000-000000000003','96400000-0000-0000-0000-000000000001',
  'Locação BlackSheep','commercial-duration-blocks',60,180,1,10,365,
  'BLOCKS',30,2,8,90,50,2
),
(
  '96400000-0000-0000-0000-000000000004','96400000-0000-0000-0000-000000000001',
  'Ensaio Signature com Experiência Fotográfica Completa e Produção Personalizada para Gestantes e Famílias',
  'commercial-duration-fixed',240,2000,1,10,365,
  'FIXED',null,null,null,null,50,2
);

insert into public.service_employees(id,service_id,employee_id) values
('96400000-0000-0000-0000-000000000005','96400000-0000-0000-0000-000000000003','96400000-0000-0000-0000-000000000002'),
('96400000-0000-0000-0000-000000000006','96400000-0000-0000-0000-000000000004','96400000-0000-0000-0000-000000000002');

insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values
('96400000-0000-0000-0000-000000000003',48,0,20,20,20),
('96400000-0000-0000-0000-000000000004',48,0,20,20,20);

select is(public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000003',210),7,'210 minutes derives seven 30-minute pricing blocks internally');
select throws_ok($$ select public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000003',217) $$,'P0001','INVALID_CONTRACTED_MINUTES','non-multiple duration is rejected server-side');
select throws_ok($$ select public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000003',30) $$,'P0001','INVALID_CONTRACTED_MINUTES','duration below service minimum is rejected');
select throws_ok($$ select public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000003',270) $$,'P0001','INVALID_CONTRACTED_MINUTES','duration above service maximum is rejected');
select is(public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000004',240),null::integer,'fixed service accepts exactly its contracted duration');
select throws_ok($$ select public.resolve_service_duration_blocks_from_minutes('96400000-0000-0000-0000-000000000004',300) $$,'P0001','INVALID_CONTRACTED_MINUTES','fixed service rejects client-provided expanded duration');

select is(public.format_contracted_duration(210),'3h30','commercial duration formats hours and minutes');
select is(public.build_commercial_description('Locação BlackSheep','BLOCKS',210),'Locação de estúdio fotográfico, 3h30','block service receives canonical rental product wording');

insert into public.customers(id,name,email,phone)
values ('96400000-0000-0000-0000-000000000007','Commercial Customer','commercial@example.com','48999991111');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,
  status,financial_status,start_at,end_at,core_start_at,core_end_at,
  duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
  hold_expires_at,commercial_value,billing_mode_snapshot
) values (
  '96400000-0000-0000-0000-000000000008','COMM-4H',
  '96400000-0000-0000-0000-000000000004','96400000-0000-0000-0000-000000000006',
  'Ensaio Signature com Experiência Fotográfica Completa e Produção Personalizada para Gestantes e Famílias',
  '96400000-0000-0000-0000-000000000007',
  'AWAITING_PAYMENT','PENDING',now()+interval '9 days 23 hours',now()+interval '10 days 4 hours',
  now()+interval '10 days',now()+interval '10 days 4 hours',
  300,240,60,0,1,now()+interval '30 minutes',2000,'CHECKOUT'
);

select is(
  public.appointment_commercial_description('96400000-0000-0000-0000-000000000008'),
  'Ensaio Signature com Experiência Fotográfica Completa e Produção Personalizada para Gestantes e Famílias, 4h',
  'one-hour preparation changes arrival but commercial product remains four hours'
);

select is(
  char_length(public.appointment_provider_commercial_description('96400000-0000-0000-0000-000000000008')) <= 150,
  true,
  'longest realistic service description remains inside provider limit'
);

select is(
  public.build_provider_commercial_description(repeat('Nome comercial muito longo ',10),'FIXED',240),
  'Atendimento fotográfico, 4h',
  'provider overflow uses explicit deterministic short form instead of truncation'
);

select is(
  public.appointment_commercial_description('96400000-0000-0000-0000-000000000008'),
  public.build_commercial_description(
    (select service_name_snapshot from public.appointments where id='96400000-0000-0000-0000-000000000008'),
    'FIXED',
    (select contracted_minutes from public.appointments where id='96400000-0000-0000-0000-000000000008')
  ),
  'appointment surface consumes the same canonical description function'
);

select * from finish();
rollback;
