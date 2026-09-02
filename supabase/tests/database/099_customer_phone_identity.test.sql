begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

select is(
  public.normalize_customer_phone_identity('48991118898'),
  '5548991118898',
  'telefone brasileiro nacional recebe codigo 55'
);

select is(
  public.normalize_customer_phone_identity('5548991118898'),
  '5548991118898',
  'telefone brasileiro ja internacional permanece estavel'
);

select is(
  public.normalize_customer_phone_identity('+55 (48) 99111-8898'),
  '5548991118898',
  'formatacao visual nao altera identidade do telefone'
);

select is(
  public.normalize_customer_phone_identity('005548991118898'),
  '5548991118898',
  'prefixo internacional 00 e normalizado'
);

select ok(
  public.normalize_customer_phone_identity('48991118898') =
  public.normalize_customer_phone_identity('5548991118898'),
  'numero nacional e numero salvo com 55 representam a mesma identidade'
);

select ok(
  position('normalize_customer_phone_identity' in pg_get_functiondef(
    'public.public_bind_checkout_customer(text,text,text,text,text,boolean)'::regprocedure
  )) > 0,
  'checkout usa normalizacao canonica ao vincular cliente'
);

select * from finish();
rollback;
