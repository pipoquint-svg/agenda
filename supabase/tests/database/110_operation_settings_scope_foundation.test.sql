begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(8);

select has_table('public','operation_setting_overrides','per-operation overrides table exists');
select col_is_pk('public','operation_setting_overrides','operation_scope','operation scope is the stable override key');
select has_function('public','service_admin_get_operation_settings_v2',array['text'],'resolved settings read model exists');

select is(
  public.service_admin_get_operation_settings_v2('SABRINA')->>'timezone',
  (select timezone from public.operation_settings where id=1),
  'SABRINA inherits global timezone when no override exists'
);

insert into public.operation_setting_overrides(
  operation_scope,public_name,timezone,checkout_hold_minutes
) values ('BLACKSHEEP','BlackSheep Estúdio','America/Sao_Paulo',15);

select is(
  public.service_admin_get_operation_settings_v2('BLACKSHEEP')->>'public_name',
  'BlackSheep Estúdio',
  'BLACKSHEEP resolves scoped public name'
);
select is(
  (public.service_admin_get_operation_settings_v2('BLACKSHEEP')->>'checkout_hold_minutes')::integer,
  15,
  'BLACKSHEEP resolves scoped checkout hold'
);
select is(
  public.service_admin_get_operation_settings_v2('BLACKSHEEP')->>'default_currency',
  (select default_currency from public.operation_settings where id=1),
  'unset values continue inheriting the legacy singleton'
);
select is(
  public.service_admin_get_operation_settings_v2('INVALID'),
  null::jsonb,
  'invalid operation scope fails closed with no resolved settings'
);

select * from finish();
rollback;
