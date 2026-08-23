begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

select ok(
  position('get_appointment_financial_summary' in pg_get_functiondef('public.get_kommo_appointment_desired_state(uuid)'::regprocedure)) > 0,
  'Kommo projection uses authoritative appointment financial summary'
);
select ok(
  position('appointment_extras' in pg_get_functiondef('public.get_kommo_appointment_desired_state(uuid)'::regprocedure)) > 0,
  'Kommo projection includes appointment extras snapshots'
);
select ok(
  position('contract_balance' in pg_get_functiondef('public.get_appointment_financial_summary(uuid)'::regprocedure)) > 0,
  'authoritative financial summary exposes contract balance for Kommo Saldo'
);

select ok(
  exists(select 1 from pg_trigger where tgrelid='public.payment_transactions'::regclass and tgname='payment_transactions_enqueue_kommo_sync' and not tgisinternal),
  'payment mutations enqueue Kommo financial refresh'
);
select ok(
  exists(select 1 from pg_trigger where tgrelid='public.appointment_extras'::regclass and tgname='appointment_extras_enqueue_kommo_sync' and not tgisinternal),
  'appointment extra mutations enqueue Kommo extras refresh'
);

select ok(
  position('EXTRAS_CHANGED' in pg_get_functiondef('public.enqueue_kommo_appointment_sync(uuid,text)'::regprocedure)) > 0,
  'Kommo outbox accepts extras-only changes'
);
select ok(
  position('FINANCIAL_CHANGED' in pg_get_functiondef('public.enqueue_kommo_appointment_sync(uuid,text)'::regprocedure)) > 0,
  'Kommo outbox accepts financial-only changes'
);
select ok(
  position('md5' in pg_get_functiondef('public.enqueue_kommo_appointment_sync(uuid,text)'::regprocedure)) > 0,
  'Kommo outbox fingerprints canonical projection for same-version changes'
);

select ok(
  not has_function_privilege('anon','public.trg_enqueue_kommo_payment_sync()','EXECUTE'),
  'anon cannot execute Kommo payment trigger helper'
);
select ok(
  not has_function_privilege('authenticated','public.trg_enqueue_kommo_extra_sync()','EXECUTE'),
  'authenticated cannot execute Kommo extras trigger helper'
);
select ok(
  not has_function_privilege('service_role','public.trg_enqueue_kommo_payment_sync()','EXECUTE'),
  'service_role cannot directly execute Kommo payment trigger helper'
);
select ok(
  not has_function_privilege('service_role','public.trg_enqueue_kommo_extra_sync()','EXECUTE'),
  'service_role cannot directly execute Kommo extras trigger helper'
);

select * from finish();
rollback;
