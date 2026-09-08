begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select has_table('public','waitlist_private_rounds','private waitlist rounds table exists');
select has_table('public','waitlist_private_round_slots','private waitlist round slots table exists');
select has_table('public','waitlist_private_round_invites','private waitlist round invites table exists');

select has_function(
  'public','service_admin_waitlist_private_round_action',array['text','jsonb','uuid'],
  'admin round dispatcher exists'
);
select has_function(
  'public','public_waitlist_private_round_action',array['text','text','jsonb'],
  'public round dispatcher exists'
);

create temporary table _round_public_def as
select pg_get_functiondef('public.public_waitlist_private_round_action(text,text,jsonb)'::regprocedure) as def;
create temporary table _round_admin_def as
select pg_get_functiondef('public.service_admin_waitlist_private_round_action(text,jsonb,uuid)'::regprocedure) as def;

select ok(
  exists(select 1 from _round_admin_def where def like '%service_admin_create_waitlist_private_slot%'),
  'round creation reuses the authoritative hidden-slot creator'
);

select ok(
  exists(select 1 from _round_public_def where def like '%for update%' and def like '%waitlist_private_round_invites%'),
  'round invite is locked so one family cannot claim two slots concurrently'
);

select ok(
  exists(select 1 from _round_public_def where def like '%public_create_waitlist_private_checkout_hold%'),
  'round checkout reuses the existing private checkout pipeline'
);

select ok(
  not has_function_privilege('anon','public.public_waitlist_private_round_action(text,text,jsonb)','EXECUTE')
  and not has_function_privilege('authenticated','public.public_waitlist_private_round_action(text,text,jsonb)','EXECUTE')
  and has_function_privilege('service_role','public.public_waitlist_private_round_action(text,text,jsonb)','EXECUTE'),
  'public round dispatcher is callable only through service role edge boundary'
);

select ok(
  not has_function_privilege('anon','public.service_admin_waitlist_private_round_action(text,jsonb,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_waitlist_private_round_action(text,jsonb,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_waitlist_private_round_action(text,jsonb,uuid)','EXECUTE'),
  'admin round dispatcher is callable only through service role edge boundary'
);

select * from finish();
rollback;
