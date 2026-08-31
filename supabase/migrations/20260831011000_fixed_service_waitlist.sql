-- Lista de espera manual para serviços FIXED sem disponibilidade.
-- Não altera disponibilidade, precificação, holds ou checkout.

create table public.service_waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  booking_page_id uuid not null references public.booking_pages(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  name text not null,
  email text not null,
  email_normalized text not null,
  whatsapp text not null,
  whatsapp_normalized text not null,
  customer_id uuid references public.customers(id) on delete set null,
  created_at timestamptz not null default now(),
  contacted_at timestamptz,
  contacted_by_admin_id uuid references public.admin_users(id) on delete set null,
  check (length(btrim(name)) between 2 and 160),
  check (length(email_normalized) between 3 and 320),
  check (length(whatsapp_normalized) between 10 and 15),
  check ((contacted_at is null and contacted_by_admin_id is null) or (contacted_at is not null and contacted_by_admin_id is not null))
);

create unique index service_waitlist_entries_service_email_uq
  on public.service_waitlist_entries(service_id,email_normalized);
create unique index service_waitlist_entries_service_whatsapp_uq
  on public.service_waitlist_entries(service_id,whatsapp_normalized);
create index service_waitlist_entries_service_created_idx
  on public.service_waitlist_entries(service_id,created_at,id);
create index service_waitlist_entries_created_idx
  on public.service_waitlist_entries(created_at,id);
create index service_waitlist_entries_customer_idx
  on public.service_waitlist_entries(customer_id) where customer_id is not null;

alter table public.service_waitlist_entries enable row level security;
revoke all on public.service_waitlist_entries from anon, authenticated;
grant all on public.service_waitlist_entries to service_role;

-- Evento interno de nova inscrição. WAITLIST_AVAILABLE permanece reservado ao evento
-- legado de disponibilidade e não é usado por este fluxo manual.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_event_key_check;
alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check check (event_key in (
    'APPOINTMENT_APPROVED','APPOINTMENT_PENDING','APPOINTMENT_REJECTED','APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','WAITLIST_SIGNUP_TEAM','BIRTHDAY',
    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','MANUAL','REFUND_FAILED','PRE_RESERVATION_CREATED'
  ));

insert into public.notification_template_configs(
  event_key,channel,audience,operation_scope,category_id,title_template,body_template,
  is_active,variable_schema,reminder_offset_minutes
)
select
  'WAITLIST_SIGNUP_TEAM','EMAIL','EMPLOYEE',null,null,
  'Nova inscrição na lista de espera — {{service.name}}',
  E'Nova inscrição na lista de espera.\n\nServiço: {{service.name}}\nNome: {{waitlist.name}}\nE-mail: {{waitlist.email}}\nWhatsApp: {{waitlist.whatsapp}}\nInscrição: {{waitlist.created_at}}\n\nO contato com esta pessoa é manual pela Gestão.',
  true,
  '["service.name","waitlist.name","waitlist.email","waitlist.whatsapp","waitlist.created_at"]'::jsonb,
  null
where not exists (
  select 1 from public.notification_template_configs
  where event_key='WAITLIST_SIGNUP_TEAM' and channel='EMAIL' and audience='EMPLOYEE'
);

-- Mantém a edição administrativa de templates sincronizada com o evento novo sem
-- reescrever a função inteira e sem perder alterações posteriores.
do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY',$old$;
  v_new text := $new$'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','WAITLIST_SIGNUP_TEAM','BIRTHDAY',$new$;
begin
  select p.oid into v_oid
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='service_admin_upsert_notification_template'
    and pg_get_function_identity_arguments(p.oid)='p_template_id uuid, p_event_key text, p_channel text, p_audience text, p_operation_scope text, p_category_id uuid, p_title_template text, p_body_template text, p_is_active boolean, p_variable_schema jsonb, p_reminder_offset_minutes integer, p_service_ids uuid[], p_actor_admin_id uuid';
  if v_oid is null then raise exception 'service_admin_upsert_notification_template not found'; end if;
  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def)=0 then raise exception 'expected notification event allowlist not found'; end if;
  execute replace(v_def,v_old,v_new);
end;
$migration$;

create or replace function public.public_create_service_waitlist_entry(
  p_booking_page_slug text,
  p_service_id uuid,
  p_name text,
  p_email text,
  p_whatsapp text
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_page_id uuid;
  v_service_name text;
  v_operation_scope text;
  v_duration_mode text;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_whatsapp text := btrim(coalesce(p_whatsapp,''));
  v_whatsapp_normalized text := regexp_replace(coalesce(p_whatsapp,''),'[^0-9]','','g');
  v_customer_id uuid;
  v_entry public.service_waitlist_entries%rowtype;
begin
  if length(v_name) < 2 or length(v_name) > 160 then
    raise exception using errcode='P0001',message='WAITLIST_NAME_INVALID';
  end if;
  if length(v_email) > 320 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode='P0001',message='WAITLIST_EMAIL_INVALID';
  end if;
  if length(v_whatsapp) > 40 or length(v_whatsapp_normalized) < 10 or length(v_whatsapp_normalized) > 15 then
    raise exception using errcode='P0001',message='WAITLIST_WHATSAPP_INVALID';
  end if;

  select bp.id,s.name,s.operation_scope,s.duration_mode
    into v_page_id,v_service_name,v_operation_scope,v_duration_mode
  from public.booking_pages bp
  join public.booking_page_services bps on bps.booking_page_id=bp.id and bps.is_active
  join public.services s on s.id=bps.service_id and s.is_active
  where bp.slug=lower(btrim(coalesce(p_booking_page_slug,'')))
    and bp.is_active
    and s.id=p_service_id;

  if not found then raise exception using errcode='P0001',message='PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE'; end if;
  if v_duration_mode <> 'FIXED' then raise exception using errcode='P0001',message='WAITLIST_FIXED_ONLY'; end if;

  select c.id into v_customer_id
  from public.customers c
  where c.anonymized_at is null
    and (
      lower(btrim(coalesce(c.email,'')))=v_email
      or regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')=v_whatsapp_normalized
    )
  order by case when lower(btrim(coalesce(c.email,'')))=v_email then 0 else 1 end,c.created_at,c.id
  limit 1;

  begin
    insert into public.service_waitlist_entries(
      booking_page_id,service_id,name,email,email_normalized,whatsapp,whatsapp_normalized,customer_id
    ) values (
      v_page_id,p_service_id,v_name,v_email,v_email,v_whatsapp,v_whatsapp_normalized,v_customer_id
    ) returning * into v_entry;
  exception when unique_violation then
    raise exception using errcode='P0001',message='WAITLIST_ALREADY_REGISTERED';
  end;

  insert into public.notification_delivery_logs(
    event_key,channel,audience,customer_id,status,attempt_count,idempotency_key,payload_snapshot
  ) values (
    'WAITLIST_SIGNUP_TEAM','EMAIL','EMPLOYEE',v_customer_id,'PENDING',0,
    'waitlist:'||v_entry.id::text||':team',
    jsonb_build_object(
      'waitlist_entry_id',v_entry.id,
      'service_id',p_service_id,
      'service_name',v_service_name,
      'operation_scope',v_operation_scope,
      'name',v_name,
      'email',v_email,
      'whatsapp',v_whatsapp,
      'created_at',v_entry.created_at
    )
  );

  return jsonb_build_object(
    'id',v_entry.id,
    'service_id',p_service_id,
    'service_name',v_service_name,
    'operation_scope',v_operation_scope,
    'customer_id',v_customer_id,
    'created_at',v_entry.created_at,
    'notification_idempotency_key','waitlist:'||v_entry.id::text||':team'
  );
end;
$function$;

create or replace function public.service_admin_role_default_permission(p_role text,p_permission text)
returns boolean
language sql
immutable
set search_path=public
as $function$
select case upper(coalesce(p_role,''))
  when 'OWNER' then true
  when 'ADMIN' then true
  when 'OPERATION' then upper(coalesce(p_permission,'')) in (
    'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','PACKAGES_VIEW',
    'WAITLIST_VIEW','WAITLIST_MANAGE'
  )
  when 'FINANCE' then upper(coalesce(p_permission,'')) in (
    'DASHBOARD_VIEW','AGENDA_VIEW','CUSTOMERS_VIEW','FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','AUDIT_VIEW'
  )
  else false
end;
$function$;

create or replace function public.service_admin_get_access_profile(p_admin_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=public
as $function$
select jsonb_build_object(
  'admin_user_id',a.id,
  'display_name',a.display_name,
  'role',a.role,
  'permissions',(
    select jsonb_object_agg(p.permission,public.service_admin_has_permission(a.id,p.permission))
    from (values
      ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),('CUSTOMER_ACCESS_DETAIL_VIEW'),
      ('FINANCE_VIEW'),('FINANCE_MANAGE'),('PACKAGES_VIEW'),('PACKAGES_MANAGE'),('SERVICES_VIEW'),('SERVICES_MANAGE'),
      ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),('LEADS_VIEW'),('LEADS_MANAGE'),('WAITLIST_VIEW'),('WAITLIST_MANAGE'),('AUDIT_VIEW'),('TEAM_MANAGE')
    ) p(permission)
  )
)
from public.admin_users a
where a.id=p_admin_id and a.is_active=true;
$function$;

create or replace function public.service_admin_set_permission(
  p_target_admin_id uuid,p_permission text,p_is_granted boolean,p_actor_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_actor_admin_id,'TEAM_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if not exists(select 1 from public.admin_users where id=p_target_admin_id) then
    raise exception using errcode='P0001',message='ADMIN_USER_NOT_FOUND';
  end if;
  if p_permission not in (
    'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW',
    'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE',
    'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','WAITLIST_VIEW','WAITLIST_MANAGE','AUDIT_VIEW','TEAM_MANAGE'
  ) then raise exception using errcode='P0001',message='ADMIN_PERMISSION_INVALID'; end if;
  if p_target_admin_id=p_actor_admin_id and p_permission='TEAM_MANAGE' and p_is_granted is false then
    raise exception using errcode='P0001',message='ADMIN_SELF_LOCKOUT_FORBIDDEN';
  end if;
  select public.service_admin_get_access_profile(p_target_admin_id) into v_before;
  insert into public.admin_user_permissions(admin_user_id,permission,is_granted,updated_by_admin_id,updated_at)
  values(p_target_admin_id,p_permission,p_is_granted,p_actor_admin_id,now())
  on conflict(admin_user_id,permission) do update
    set is_granted=excluded.is_granted,updated_by_admin_id=excluded.updated_by_admin_id,updated_at=now();
  select public.service_admin_get_access_profile(p_target_admin_id) into v_after;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_actor_admin_id,'ADMIN_USER',p_target_admin_id,'PERMISSION_CHANGED',v_before,v_after,'ADMIN');
  return v_after;
end;
$function$;

create or replace function public.service_admin_list_waitlist(
  p_service_id uuid,
  p_limit integer,
  p_after_created_at timestamptz,
  p_after_id uuid,
  p_admin_id uuid
)
returns table(
  id uuid,
  service_id uuid,
  service_name text,
  operation_scope text,
  name text,
  email text,
  whatsapp text,
  created_at timestamptz,
  customer_id uuid,
  customer_name text,
  is_existing_customer boolean,
  contacted_at timestamptz,
  contacted_by_admin_id uuid,
  contacted_by_name text
)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $function$
declare
  v_limit integer := greatest(1,least(coalesce(p_limit,50),100));
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_VIEW') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if (p_after_created_at is null) <> (p_after_id is null) then
    raise exception using errcode='P0001',message='WAITLIST_CURSOR_INVALID';
  end if;

  return query
  select
    w.id,w.service_id,s.name,s.operation_scope,w.name,w.email,w.whatsapp,w.created_at,
    coalesce(w.customer_id,matched.id) as customer_id,
    coalesce(c.name,matched.name) as customer_name,
    coalesce(w.customer_id,matched.id) is not null as is_existing_customer,
    w.contacted_at,w.contacted_by_admin_id,contacted.display_name
  from public.service_waitlist_entries w
  join public.services s on s.id=w.service_id
  left join public.customers c on c.id=w.customer_id and c.anonymized_at is null
  left join lateral (
    select candidate.id,candidate.name
    from public.customers candidate
    where w.customer_id is null
      and candidate.anonymized_at is null
      and (
        lower(btrim(coalesce(candidate.email,'')))=w.email_normalized
        or regexp_replace(coalesce(candidate.phone,''),'[^0-9]','','g')=w.whatsapp_normalized
      )
    order by case when lower(btrim(coalesce(candidate.email,'')))=w.email_normalized then 0 else 1 end,candidate.created_at,candidate.id
    limit 1
  ) matched on true
  left join public.admin_users contacted on contacted.id=w.contacted_by_admin_id
  where (p_service_id is null or w.service_id=p_service_id)
    and (p_after_created_at is null or (w.created_at,w.id)>(p_after_created_at,p_after_id))
  order by w.created_at,w.id
  limit v_limit + 1;
end;
$function$;

create or replace function public.service_admin_mark_waitlist_contacted(
  p_waitlist_entry_id uuid,p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_before public.service_waitlist_entries%rowtype;
  v_after public.service_waitlist_entries%rowtype;
  v_admin_name text;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select * into v_before from public.service_waitlist_entries where id=p_waitlist_entry_id for update;
  if not found then raise exception using errcode='P0001',message='WAITLIST_ENTRY_NOT_FOUND'; end if;

  if v_before.contacted_at is null then
    update public.service_waitlist_entries
      set contacted_at=now(),contacted_by_admin_id=p_admin_id
    where id=p_waitlist_entry_id
    returning * into v_after;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(
      p_admin_id,'SERVICE_WAITLIST_ENTRY',p_waitlist_entry_id,'WAITLIST_CONTACTED',
      jsonb_build_object('contacted_at',null,'contacted_by_admin_id',null),
      jsonb_build_object('contacted_at',v_after.contacted_at,'contacted_by_admin_id',p_admin_id),
      'ADMIN_UI'
    );
  else
    v_after := v_before;
  end if;

  select display_name into v_admin_name from public.admin_users where id=v_after.contacted_by_admin_id;
  return jsonb_build_object(
    'id',v_after.id,
    'contacted_at',v_after.contacted_at,
    'contacted_by_admin_id',v_after.contacted_by_admin_id,
    'contacted_by_name',v_admin_name
  );
end;
$function$;

revoke all on function public.public_create_service_waitlist_entry(text,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.public_create_service_waitlist_entry(text,uuid,text,text,text) to service_role;
revoke all on function public.service_admin_list_waitlist(uuid,integer,timestamptz,uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_list_waitlist(uuid,integer,timestamptz,uuid,uuid) to service_role;
revoke all on function public.service_admin_mark_waitlist_contacted(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_mark_waitlist_contacted(uuid,uuid) to service_role;

comment on table public.service_waitlist_entries is 'Lista de espera manual por serviço. Apenas serviços duration_mode=FIXED podem receber inscrições pelo fluxo público.';
comment on function public.public_create_service_waitlist_entry(text,uuid,text,text,text) is 'Captura pública validada de lista de espera para FIXED. Não consulta nem altera disponibilidade.';