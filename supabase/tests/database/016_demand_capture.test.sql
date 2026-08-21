begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(9);

select has_table('public', 'demand_capture', 'demand capture has its isolated table');
select col_type_is('public', 'demand_capture', 'created_at', 'timestamp with time zone', 'created_at is timestamptz');

select ok(
  (public.create_or_touch_demand_capture(
    'Pessoa Teste',
    '5548999991234',
    'pessoa@teste.local',
    'brand-test',
    'Servico Teste',
    ((now() at time zone 'America/Sao_Paulo')::date + 2),
    'MANHA',
    'Observacao',
    'site',
    'campaign-test',
    true,
    'consent-v1',
    now()
  )->>'created')::boolean,
  'valid demand creates a record'
);

select is(
  (select count(*)::integer from public.demand_capture where whatsapp = '5548999991234'),
  1,
  'valid submission creates exactly one record'
);

select throws_ok(
  $$select public.create_or_touch_demand_capture(
    'Sem Consentimento',
    '5548999995678',
    'sem@consentimento.local',
    'brand-test',
    'Servico Teste',
    ((now() at time zone 'America/Sao_Paulo')::date + 3),
    'TARDE',
    null,
    'site',
    null,
    false,
    'consent-v1',
    null
  )$$,
  'P0001',
  'CONSENT_REQUIRED',
  'submission without consent is rejected server side'
);

select ok(
  not (public.create_or_touch_demand_capture(
    'Pessoa Teste Atualizada',
    '5548999991234',
    'outro@teste.local',
    'brand-test',
    'Servico Teste',
    ((now() at time zone 'America/Sao_Paulo')::date + 2),
    'MANHA',
    null,
    'site',
    'campaign-test',
    true,
    'consent-v1',
    now()
  )->>'created')::boolean,
  'duplicate demand within 24 hours responds successfully without creating'
);

select is(
  (select count(*)::integer from public.demand_capture where whatsapp = '5548999991234'),
  1,
  'duplicate demand does not create a second record'
);

select throws_ok(
  $$select public.create_or_touch_demand_capture(
    'Data Passada',
    '5548999997777',
    'data@passada.local',
    'brand-test',
    'Servico Teste',
    ((now() at time zone 'America/Sao_Paulo')::date - 1),
    'NOITE',
    null,
    'site',
    null,
    true,
    'consent-v1',
    now()
  )$$,
  'P0001',
  'DESIRED_DATE_IN_PAST',
  'past desired date is rejected server side'
);

select ok(
  (select created_at <= now() and created_at > now() - interval '1 minute'
   from public.demand_capture where whatsapp = '5548999991234'),
  'created_at stores the current instant'
);

select * from finish();
rollback;
