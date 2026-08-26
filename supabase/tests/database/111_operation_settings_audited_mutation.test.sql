begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('97700000-0000-0000-0000-000000000001','authenticated','authenticated','settings-owner@example.com','{}','{}',now(),now()),
  ('97700000-0000-0000-0000-000000000002','authenticated','authenticated','settings-operation@example.com','{}','{}',now(),now());

insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values
  ('97700000-0000-0000-0000-000000000011','97700000-0000-0000-0000-000000000001','Settings Owner','OWNER',true),
  ('97700000-0000-0000-0000-000000000012','97700000-0000-0000-0000-000000000002','Settings Operation','OPERATION',true);

select has_column('public','operation_setting_overrides','id','override rows have stable audit entity id');
select has_function('public','service_admin_update_operation_settings_v2',array['text','jsonb','uuid'],'audited settings mutation exists');
select ok(not has_function_privilege('anon','public.service_admin_update_operation_settings_v2(text,jsonb,uuid)','EXECUTE'),'anon cannot execute settings mutation');
select ok(not has_function_privilege('authenticated','public.service_admin_update_operation_settings_v2(text,jsonb,uuid)','EXECUTE'),'authenticated cannot execute settings mutation');
select ok(has_function_privilege('service_role','public.service_admin_update_operation_settings_v2(text,jsonb,uuid)','EXECUTE'),'service_role can execute settings mutation');

select throws_ok(
  $$select public.service_admin_update_operation_settings_v2('BLACKSHEEP','{"public_name":"Blocked"}'::jsonb,'97700000-0000-0000-0000-000000000012')$$,
  'P0001','ADMIN_PERMISSION_DENIED','OPERATION role cannot manage scoped settings'
);

create temporary table settings_result as
select public.service_admin_update_operation_settings_v2(
  'BLACKSHEEP',
  '{"public_name":"BlackSheep Estúdio","checkout_hold_minutes":20}'::jsonb,
  '97700000-0000-0000-0000-000000000011'
) data;

select is((select data->>'public_name' from settings_result),'BlackSheep Estúdio','owner updates scoped public name');
select is((select (data->>'checkout_hold_minutes')::integer from settings_result),20,'owner updates scoped checkout hold');
select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id='97700000-0000-0000-0000-000000000011'
    and entity_type='OPERATION_SETTINGS'
    and action='OPERATION_SETTINGS_CHANGED'
    and before_json->>'operation_scope'='BLACKSHEEP'
    and after_json->>'public_name'='BlackSheep Estúdio'
),'mutation records before/after audit event');

insert into public.admin_user_permissions(admin_user_id,permission,is_granted,updated_by_admin_id)
values ('97700000-0000-0000-0000-000000000011','FINANCE_MANAGE',false,'97700000-0000-0000-0000-000000000011');

select throws_ok(
  $$select public.service_admin_update_operation_settings_v2('BLACKSHEEP','{"pix_discount_percent":3}'::jsonb,'97700000-0000-0000-0000-000000000011')$$,
  'P0001','ADMIN_FINANCE_PERMISSION_REQUIRED','PIX discount requires finance permission in addition to services manage'
);

update public.admin_user_permissions
set is_granted=true
where admin_user_id='97700000-0000-0000-0000-000000000011' and permission='FINANCE_MANAGE';

select is(
  (public.service_admin_update_operation_settings_v2('BLACKSHEEP','{"pix_discount_percent":3}'::jsonb,'97700000-0000-0000-0000-000000000011')->>'pix_discount_percent')::numeric,
  3::numeric,
  'finance-authorized owner can update PIX discount'
);

select is(
  public.service_admin_update_operation_settings_v2('BLACKSHEEP','{"public_name":null}'::jsonb,'97700000-0000-0000-0000-000000000011')->>'public_name',
  (select operation_name from public.operation_settings where id=1),
  'null resets a scoped field to global inheritance'
);

select throws_ok(
  $$select public.service_admin_update_operation_settings_v2('BLACKSHEEP','{"unknown_setting":true}'::jsonb,'97700000-0000-0000-0000-000000000011')$$,
  'P0001','OPERATION_SETTINGS_PATCH_KEY_INVALID','unknown settings fail closed'
);
select throws_ok(
  $$select public.service_admin_update_operation_settings_v2('INVALID','{"public_name":"X"}'::jsonb,'97700000-0000-0000-0000-000000000011')$$,
  'P0001','OPERATION_SCOPE_INVALID','invalid operation scope fails closed'
);

select * from finish();
rollback;
