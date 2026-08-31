begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

create temporary table _notification_upsert_def as
select pg_get_functiondef(
  'public.service_admin_upsert_notification_template(uuid,text,text,text,text,uuid,text,text,boolean,jsonb,integer,uuid[],uuid)'::regprocedure
) as def;

select ok(
  exists (select 1 from _notification_upsert_def where def is not null),
  'notification admin upsert function exists'
);

select ok(
  exists (select 1 from _notification_upsert_def where def like '%PRE_RESERVATION_CREATED%'),
  'pre-reservation notification event is editable and can be toggled in admin'
);

select ok(
  exists (select 1 from _notification_upsert_def where def like '%REFUND_FAILED%'),
  'refund-failed notification event is editable and can be toggled in admin'
);

select ok(
  not exists (
    select 1
    from public.notification_template_configs t
    cross join _notification_upsert_def f
    where position(quote_literal(t.event_key) in f.def) = 0
  ),
  'every persisted notification template event is accepted by the admin mutation boundary'
);

select * from finish();
rollback;
