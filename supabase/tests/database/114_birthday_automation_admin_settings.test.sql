begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(11);

select has_function('public','service_admin_list_birthday_automation_settings',array[]::text[],'birthday settings admin list RPC exists');
select has_function(
  'public',
  'service_admin_update_birthday_automation_settings',
  array['text','boolean','boolean','boolean','boolean','integer','text','text','numeric','integer','integer','integer','uuid'],
  'birthday settings audited update RPC exists'
);
select ok(
  not has_function_privilege('anon','public.service_admin_list_birthday_automation_settings()','EXECUTE'),
  'anon cannot execute birthday settings list'
);
select ok(
  not has_function_privilege('authenticated','public.service_admin_list_birthday_automation_settings()','EXECUTE'),
  'authenticated cannot execute birthday settings list'
);
select ok(
  has_function_privilege('service_role','public.service_admin_list_birthday_automation_settings()','EXECUTE'),
  'service role can execute birthday settings list'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid)',
    'EXECUTE'
  ),
  'anon cannot mutate birthday settings'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid)',
    'EXECUTE'
  ),
  'authenticated cannot mutate birthday settings'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid)',
    'EXECUTE'
  ),
  'service role can invoke audited birthday settings mutation'
);
select is((select count(*)::integer from public.service_admin_list_birthday_automation_settings()),2,'admin list returns both operation settings rows');
select is((select count(*)::integer from public.service_admin_list_birthday_automation_settings() where is_active),0,'birthday settings remain disabled after migration');
select is((select count(*)::integer from public.birthday_automation_cycles),0,'admin settings migration creates no birthday execution cycles');

select * from finish();
rollback;