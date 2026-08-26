-- Issue #216 — controlled V1.5 notification runtime resolver.
-- Expand-only. This migration does not enable any provider or enqueue any delivery.
-- Runtime activation remains behind Edge environment gates.

create or replace function public.resolve_notification_template(
  p_event_key text,
  p_channel text,
  p_audience text,
  p_service_id uuid
)
returns table (
  id uuid,
  event_key text,
  channel text,
  audience text,
  operation_scope text,
  category_id uuid,
  title_template text,
  body_template text,
  variable_schema jsonb,
  reminder_offset_minutes integer,
  specificity integer
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with service_context as (
    select s.id as service_id, s.category_id, s.operation_scope
    from public.services s
    where s.id = p_service_id
  ), candidates as (
    select
      t.id,
      t.event_key,
      t.channel,
      t.audience,
      t.operation_scope,
      t.category_id,
      t.title_template,
      t.body_template,
      t.variable_schema,
      t.reminder_offset_minutes,
      t.updated_at,
      case
        when exists (
          select 1 from public.notification_template_services nts
          where nts.template_id = t.id and nts.service_id = sc.service_id
        ) then 400
        when t.category_id is not null and t.category_id = sc.category_id then 300
        when t.operation_scope is not null and t.operation_scope = sc.operation_scope then 200
        else 100
      end as specificity
    from public.notification_template_configs t
    cross join service_context sc
    where t.is_active
      and t.event_key = p_event_key
      and t.channel = p_channel
      and t.audience = p_audience
      and (t.operation_scope is null or t.operation_scope = sc.operation_scope)
      and (t.category_id is null or t.category_id = sc.category_id)
      and (
        not exists (
          select 1 from public.notification_template_services assigned
          where assigned.template_id = t.id
        )
        or exists (
          select 1 from public.notification_template_services matched
          where matched.template_id = t.id and matched.service_id = sc.service_id
        )
      )
  )
  select
    c.id, c.event_key, c.channel, c.audience, c.operation_scope, c.category_id,
    c.title_template, c.body_template, c.variable_schema, c.reminder_offset_minutes,
    c.specificity
  from candidates c
  order by c.specificity desc, c.updated_at desc, c.id
  limit 1;
$$;

revoke all on function public.resolve_notification_template(text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.resolve_notification_template(text,text,text,uuid) to service_role;

comment on function public.resolve_notification_template(text,text,text,uuid) is
  'Deterministic active-template resolution: service > category > operation > global. Service-scoped templates never leak to other services. Provider activation is external to this function.';
