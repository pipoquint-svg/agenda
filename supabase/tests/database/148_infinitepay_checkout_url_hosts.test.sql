begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

create temporary table ip_checkout_host_contract as
select pg_get_functiondef(
  'public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)'::regprocedure
) as definition;

select ok(
  position('^https://checkout[.]infinitepay[.]com[.]br(?:/|$)' in (select definition from ip_checkout_host_contract)) > 0,
  'database URL validator keeps the documented checkout.infinitepay.com.br host'
);

select ok(
  position('^https://checkout[.]infinitepay[.]io(?:/|$)' in (select definition from ip_checkout_host_contract)) > 0,
  'database URL validator accepts the live checkout.infinitepay.io host'
);

select ok(
  'https://checkout.infinitepay.com.br/local-test' ~ '^https://checkout[.]infinitepay[.]com[.]br(?:/|$)',
  'checkout.infinitepay.com.br matches the exact host-boundary rule'
);

select ok(
  'https://checkout.infinitepay.io/local-test' ~ '^https://checkout[.]infinitepay[.]io(?:/|$)',
  'checkout.infinitepay.io matches the exact host-boundary rule'
);

select ok(
  not ('https://checkout.infinitepay.io.evil.example/local-test' ~ '^https://checkout[.]infinitepay[.]io(?:/|$)'),
  'lookalike suffix host cannot pass the InfinitePay .io allowlist'
);

select ok(
  not ('https://evil.checkout.infinitepay.io/local-test' ~ '^https://checkout[.]infinitepay[.]io(?:/|$)'),
  'lookalike prefixed host cannot pass the InfinitePay .io allowlist'
);

select * from finish();
rollback;
