begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select ok(
  to_regprocedure('public.service_calculate_payment_cash_amount(numeric,text,numeric)') is not null,
  'authoritative payment cash calculator exists'
);

select is(
  (public.service_calculate_payment_cash_amount(180, 'PIX', 5)->>'cash_amount')::numeric,
  171.00::numeric,
  'PIX 5 percent preview for full R$180 is R$171'
);

select is(
  (public.service_calculate_payment_cash_amount(180, 'PIX', 5)->>'payment_discount_amount')::numeric,
  9.00::numeric,
  'PIX discount amount is R$9 for R$180'
);

select is(
  (public.service_calculate_payment_cash_amount(90, 'PIX', 5)->>'cash_amount')::numeric,
  85.50::numeric,
  'PIX 5 percent preview for minimum R$90 is R$85.50'
);

select is(
  (public.service_calculate_payment_cash_amount(180, 'CARD', 5)->>'cash_amount')::numeric,
  180.00::numeric,
  'card preview never receives PIX discount'
);

select ok(
  to_regprocedure('public.service_get_public_payment_method_preview(text)') is not null,
  'service-role payment method preview exists'
);

select is(
  (select provolatile::text from pg_proc where oid='public.service_get_public_payment_method_preview(text)'::regprocedure),
  'v',
  'payment preview is volatile because token resolution records usage and takes a row lock'
);

select throws_ok(
  $$select public.service_get_public_payment_method_preview('00000000000000000000000000000000')$$,
  'P0001',
  'APPOINTMENT_TOKEN_INVALID',
  'payment preview reaches token validation instead of failing as a read-only transaction'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_get_public_payment_method_preview(text)', 'EXECUTE'),
  'authenticated browser role cannot call preview RPC directly'
);

select ok(
  has_function_privilege('service_role', 'public.service_get_public_payment_method_preview(text)', 'EXECUTE'),
  'service role can call preview RPC behind Edge boundary'
);

select ok(
  pg_get_functiondef('public.create_payment_intent_v2(uuid,text,text,text)'::regprocedure)
    like '%service_calculate_payment_cash_amount%',
  'payment intent v2 uses the same authoritative cash calculator as preview'
);

select * from finish();
rollback;
