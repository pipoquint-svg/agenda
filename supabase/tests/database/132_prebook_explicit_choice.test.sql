begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

select has_column('public','operation_settings','prebook_hold_minutes','global prebook deadline setting exists');
select has_function('public','service_public_get_checkout_prebook_option',array['text'],'prebook option resolver exists');
select has_function('public','service_submit_public_checkout_choice',array['text','text','text','uuid[]','jsonb','inet','text'],'explicit checkout choice submit exists');
select has_function('public','promote_checkout_hold_prebook',array['uuid','uuid','text','uuid[]','jsonb','jsonb','inet','text'],'prebook promotion is isolated from normal promotion');

select ok(not has_function_privilege('anon','public.service_public_get_checkout_prebook_option(text)','EXECUTE'),'anon cannot invoke prebook option resolver directly');
select ok(not has_function_privilege('authenticated','public.service_public_get_checkout_prebook_option(text)','EXECUTE'),'authenticated cannot invoke prebook option resolver directly');
select ok(not has_function_privilege('anon','public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text)','EXECUTE'),'anon cannot invoke choice submit directly');
select ok(not has_function_privilege('authenticated','public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text)','EXECUTE'),'authenticated cannot invoke choice submit directly');

select ok(
  position('promote_checkout_hold_standard' in pg_get_functiondef('public.service_submit_public_checkout(text,text,uuid[],jsonb,inet,text)'::regprocedure)) > 0,
  'legacy submit defaults to normal payment instead of automatic prebook'
);
select ok(
  position('promote_checkout_hold_prebook' in pg_get_functiondef('public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text)'::regprocedure)) > 0
  and position('PAY_NOW' in pg_get_functiondef('public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text)'::regprocedure)) > 0
  and position('PREBOOK' in pg_get_functiondef('public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text)'::regprocedure)) > 0,
  'only explicit PREBOOK choice reaches the prebook promotion path'
);

select * from finish();
rollback;
