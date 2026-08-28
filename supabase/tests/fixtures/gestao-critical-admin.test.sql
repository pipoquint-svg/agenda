begin;
select plan(2);

select has_function(
  'public',
  'qa_create_gestao_admin_profile',
  array['uuid', 'text'],
  'helper local de perfil admin existe'
);

select function_privs_are(
  'public',
  'qa_create_gestao_admin_profile',
  array['uuid', 'text'],
  'service_role',
  array['EXECUTE'],
  'somente service_role recebe execução explícita para o helper de teste'
);

select * from finish();
rollback;
