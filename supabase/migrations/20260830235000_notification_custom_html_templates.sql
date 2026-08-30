alter table public.notification_template_configs
  add column if not exists html_template text null;

alter table public.notification_template_configs
  drop constraint if exists notification_template_html_size_check;

alter table public.notification_template_configs
  add constraint notification_template_html_size_check
  check (html_template is null or octet_length(html_template) <= 90000);

create or replace function public.service_admin_list_notification_templates_v2()
returns table(
  id uuid,
  event_key text,
  channel text,
  audience text,
  operation_scope text,
  category_id uuid,
  category_name text,
  title_template text,
  body_template text,
  html_template text,
  is_active boolean,
  variable_schema jsonb,
  reminder_offset_minutes integer,
  service_ids uuid[],
  version_count bigint,
  updated_at timestamptz
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    t.id,
    t.event_key,
    t.channel,
    t.audience,
    t.operation_scope,
    t.category_id,
    c.name,
    t.title_template,
    t.body_template,
    t.html_template,
    t.is_active,
    t.variable_schema,
    t.reminder_offset_minutes,
    coalesce(array_agg(distinct ts.service_id) filter(where ts.service_id is not null),'{}'::uuid[]),
    (select count(*) from public.notification_template_versions v where v.template_id=t.id),
    t.updated_at
  from public.notification_template_configs t
  left join public.categories c on c.id=t.category_id
  left join public.notification_template_services ts on ts.template_id=t.id
  group by t.id,c.name
  order by t.event_key,t.channel,t.audience,t.updated_at desc;
$function$;

create or replace function public.service_admin_upsert_notification_template_v2(
  p_template_id uuid,
  p_event_key text,
  p_channel text,
  p_audience text,
  p_operation_scope text,
  p_category_id uuid,
  p_title_template text,
  p_body_template text,
  p_html_template text,
  p_is_active boolean,
  p_variable_schema jsonb,
  p_reminder_offset_minutes integer,
  p_service_ids uuid[],
  p_actor_admin_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_version integer;
  v_html text := nullif(btrim(coalesce(p_html_template, '')), '');
begin
  if p_event_key not in (
    'APPOINTMENT_APPROVED','APPOINTMENT_PENDING','APPOINTMENT_REJECTED','APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY',
    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','PRE_RESERVATION_CREATED','REFUND_FAILED','MANUAL'
  ) then raise exception 'NOTIFICATION_EVENT_INVALID'; end if;
  if p_channel not in ('EMAIL','GOOGLE_CALENDAR') then raise exception 'NOTIFICATION_CHANNEL_INVALID'; end if;
  if p_audience not in ('CUSTOMER','EMPLOYEE') then raise exception 'NOTIFICATION_AUDIENCE_INVALID'; end if;
  if p_operation_scope is not null and p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception 'NOTIFICATION_OPERATION_SCOPE_INVALID';
  end if;
  if coalesce(btrim(p_title_template), '') = '' then raise exception 'NOTIFICATION_TITLE_REQUIRED'; end if;
  if p_variable_schema is null or jsonb_typeof(p_variable_schema) <> 'array' then raise exception 'NOTIFICATION_VARIABLE_SCHEMA_INVALID'; end if;
  if p_reminder_offset_minutes is not null and p_reminder_offset_minutes < 0 then raise exception 'NOTIFICATION_REMINDER_OFFSET_INVALID'; end if;
  if v_html is not null and octet_length(v_html) > 90000 then raise exception 'NOTIFICATION_HTML_TOO_LARGE'; end if;

  if p_category_id is not null and not exists (select 1 from public.categories where id = p_category_id) then
    raise exception 'NOTIFICATION_CATEGORY_NOT_FOUND';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    where not exists (select 1 from public.services s where s.id = sid)
  ) then raise exception 'NOTIFICATION_SERVICE_NOT_FOUND'; end if;

  if p_template_id is null then
    insert into public.notification_template_configs (
      event_key, channel, audience, operation_scope, category_id, title_template, body_template, html_template,
      is_active, variable_schema, reminder_offset_minutes, created_by_admin_id, updated_by_admin_id
    ) values (
      p_event_key, p_channel, p_audience, p_operation_scope, p_category_id, btrim(p_title_template), coalesce(p_body_template,''), v_html,
      coalesce(p_is_active,false), p_variable_schema, p_reminder_offset_minutes, p_actor_admin_id, p_actor_admin_id
    ) returning id into v_id;
  else
    select to_jsonb(t) into v_before from public.notification_template_configs t where t.id = p_template_id for update;
    if v_before is null then raise exception 'NOTIFICATION_TEMPLATE_NOT_FOUND'; end if;
    update public.notification_template_configs
      set event_key = p_event_key,
          channel = p_channel,
          audience = p_audience,
          operation_scope = p_operation_scope,
          category_id = p_category_id,
          title_template = btrim(p_title_template),
          body_template = coalesce(p_body_template,''),
          html_template = v_html,
          is_active = coalesce(p_is_active,false),
          variable_schema = p_variable_schema,
          reminder_offset_minutes = p_reminder_offset_minutes,
          updated_by_admin_id = p_actor_admin_id,
          updated_at = now()
      where id = p_template_id;
    v_id := p_template_id;
  end if;

  delete from public.notification_template_services where template_id = v_id;
  insert into public.notification_template_services(template_id, service_id)
    select v_id, sid from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    on conflict do nothing;

  select to_jsonb(t) || jsonb_build_object(
    'service_ids', coalesce((select jsonb_agg(ts.service_id order by ts.service_id) from public.notification_template_services ts where ts.template_id = v_id), '[]'::jsonb)
  ) into v_after
  from public.notification_template_configs t where t.id = v_id;

  select coalesce(max(version_number),0) + 1 into v_version
  from public.notification_template_versions where template_id = v_id;

  insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
  values (v_id, v_version, v_after, p_actor_admin_id);

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_actor_admin_id,
    'NOTIFICATION_TEMPLATE',
    v_id,
    case when v_before is null then 'CREATE' else 'UPDATE' end,
    v_before,
    v_after,
    'ADMIN'
  );

  return v_id;
end;
$function$;

create or replace function public.resolve_notification_template_v2(
  p_event_key text,
  p_channel text,
  p_audience text,
  p_service_id uuid
)
returns table(
  id uuid,
  event_key text,
  channel text,
  audience text,
  operation_scope text,
  category_id uuid,
  title_template text,
  body_template text,
  html_template text,
  variable_schema jsonb,
  reminder_offset_minutes integer,
  specificity integer
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with service_context as (
    select s.id service_id,s.category_id,s.operation_scope
    from public.services s
    where s.id=p_service_id
  ), candidates as (
    select
      t.id,t.event_key,t.channel,t.audience,t.operation_scope,t.category_id,
      t.title_template,t.body_template,t.html_template,t.variable_schema,t.reminder_offset_minutes,t.updated_at,
      case
        when exists(select 1 from public.notification_template_services nts where nts.template_id=t.id and nts.service_id=sc.service_id) then 400
        when t.category_id is not null and t.category_id=sc.category_id then 300
        when t.operation_scope is not null and t.operation_scope=sc.operation_scope then 200
        else 100
      end specificity
    from public.notification_template_configs t
    cross join service_context sc
    where t.is_active
      and t.event_key=p_event_key
      and t.channel=p_channel
      and t.audience=p_audience
      and (t.operation_scope is null or t.operation_scope=sc.operation_scope)
      and (t.category_id is null or t.category_id=sc.category_id)
      and (
        not exists(select 1 from public.notification_template_services assigned where assigned.template_id=t.id)
        or exists(select 1 from public.notification_template_services matched where matched.template_id=t.id and matched.service_id=sc.service_id)
      )
  )
  select
    c.id,c.event_key,c.channel,c.audience,c.operation_scope,c.category_id,
    c.title_template,c.body_template,c.html_template,c.variable_schema,c.reminder_offset_minutes,c.specificity
  from candidates c
  order by c.specificity desc,c.updated_at desc,c.id
  limit 1;
$function$;
