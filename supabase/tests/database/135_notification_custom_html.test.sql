begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

select has_column('public', 'notification_template_configs', 'html_template', 'notification templates store optional custom HTML');

select col_is_null('public', 'notification_template_configs', 'html_template', 'custom HTML remains optional for legacy templates');

select has_function('public', 'service_admin_list_notification_templates_v2', array[]::text[], 'admin v2 list function exists');

select has_function(
  'public',
  'resolve_notification_template_v2',
  array['text','text','text','uuid'],
  'runtime v2 resolver exists'
);

select ok(
  to_regprocedure('public.service_admin_upsert_notification_template_v2(uuid,text,text,text,text,uuid,text,text,text,boolean,jsonb,integer,uuid[],uuid)') is not null,
  'admin v2 mutation function exists'
);

select ok(
  pg_get_functiondef('public.service_admin_list_notification_templates_v2()'::regprocedure) like '%html_template%',
  'admin list exposes custom HTML'
);

select ok(
  pg_get_functiondef('public.resolve_notification_template_v2(text,text,text,uuid)'::regprocedure) like '%html_template%',
  'runtime resolver exposes custom HTML'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'notification_template_configs'
      and c.conname = 'notification_template_html_size_check'
      and pg_get_constraintdef(c.oid) like '%90000%'
  ),
  'database keeps custom HTML below the email clipping guardrail'
);

select * from finish();
rollback;
