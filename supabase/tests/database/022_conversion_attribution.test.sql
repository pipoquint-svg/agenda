begin;

select plan(8);

select has_column('public', 'checkout_holds', 'attribution_json', 'checkout holds store attribution');
select has_column('public', 'appointments', 'attribution_json', 'appointments store attribution');

select is(
  public.sanitize_public_attribution('{"utm_source":"meta","utm_campaign":"gestante","email":"cliente@example.com"}'::jsonb)->>'utm_source',
  'meta',
  'allowed UTM source is preserved'
);

select ok(
  not (public.sanitize_public_attribution('{"utm_source":"meta","email":"cliente@example.com","phone":"48999999999","cpf":"123"}'::jsonb) ?| array['email','phone','cpf']),
  'PII-shaped keys are discarded by the public attribution sanitizer'
);

select is(
  length(public.sanitize_public_attribution(jsonb_build_object('utm_campaign', repeat('x', 250)))->>'utm_campaign'),
  180,
  'campaign values are length bounded'
);

select ok(
  has_function_privilege('anon', 'public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)', 'EXECUTE'),
  'anon can call the tracked public hold wrapper'
);

select ok(
  not has_function_privilege('anon', 'public.sanitize_public_attribution(jsonb)', 'EXECUTE'),
  'anon cannot call the sanitizer directly'
);

select has_trigger(
  'public',
  'checkout_holds',
  'checkout_hold_copy_attribution_trg',
  'promotion copies attribution to the appointment'
);

select * from finish();
rollback;
