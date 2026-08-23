-- Complete the admin-side authorship chain required by Agenda issue #83.
-- Business audit_logs remain the domain audit ledger. This table stores the
-- request/actor evidence that audit_logs historically could not represent.

create table public.appointment_authorship_events (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  origin text not null check (origin in ('CLIENT_TOKEN','ADMIN_UI','SYSTEM_JOB','PROVIDER_WEBHOOK')),
  action text not null,
  admin_user_id uuid references public.admin_users(id) on delete set null,
  actor_role text,
  actor_permissions text[] not null default '{}'::text[],
  appointment_access_token_id uuid references public.appointment_access_tokens(id) on delete restrict,
  provider text,
  provider_event_id text,
  before_json jsonb,
  after_json jsonb,
  reason text,
  ip_address inet,
  user_agent text,
  request_id text,
  session_id text,
  occurred_at timestamptz not null default clock_timestamp(),
  network_retain_until timestamptz not null default (clock_timestamp() + interval '5 years')
);

create index appointment_authorship_events_appointment_time_idx
  on public.appointment_authorship_events(appointment_id, occurred_at, id);

alter table public.appointment_authorship_events enable row level security;
revoke all on table public.appointment_authorship_events from public, anon, authenticated, service_role;

create or replace function public.reject_appointment_authorship_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception using errcode = '42501', message = 'APPOINTMENT_AUTHORSHIP_APPEND_ONLY';
end;
$$;

create trigger appointment_authorship_events_append_only
before update or delete or truncate on public.appointment_authorship_events
for each statement execute function public.reject_appointment_authorship_mutation();

create or replace function public.service_admin_effective_permission_list(p_admin_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(p.permission order by p.permission), '{}'::text[])
  from (values
    ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),
    ('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),
    ('FINANCE_VIEW'),('FINANCE_MANAGE'),
    ('PACKAGES_VIEW'),('PACKAGES_MANAGE'),
    ('SERVICES_VIEW'),('SERVICES_MANAGE'),
    ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),
    ('AUDIT_VIEW'),('TEAM_MANAGE')
  ) p(permission)
  where public.service_admin_has_permission(p_admin_id, p.permission);
$$;

create or replace function public.service_appointment_authorship_snapshot(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', a.id,
    'public_code', a.public_code,
    'service_id', a.service_id,
    'service_employee_id', a.service_employee_id,
    'status', a.status,
    'financial_status', a.financial_status,
    'start_at', a.start_at,
    'end_at', a.end_at,
    'duration_minutes', a.duration_minutes,
    'duration_blocks', a.duration_blocks,
    'contracted_minutes', a.contracted_minutes,
    'people_count', a.people_count,
    'commercial_value', a.commercial_value,
    'confirmed_at', a.confirmed_at,
    'completed_at', a.completed_at,
    'cancelled_at', a.cancelled_at,
    'cancel_reason', a.cancel_reason,
    'no_show_at', a.no_show_at,
    'attendance_status', a.attendance_status,
    'core_start_at', a.core_start_at,
    'core_end_at', a.core_end_at,
    'version', a.version,
    'updated_at', a.updated_at
  )
  from public.appointments a
  where a.id = p_appointment_id;
$$;

create or replace function public.service_record_appointment_authorship_event(
  p_appointment_id uuid,
  p_origin text,
  p_action text,
  p_admin_id uuid default null,
  p_token_id uuid default null,
  p_before_json jsonb default null,
  p_after_json jsonb default null,
  p_reason text default null,
  p_ip inet default null,
  p_user_agent text default null,
  p_request_id text default null,
  p_session_id text default null,
  p_provider text default null,
  p_provider_event_id text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_origin text := upper(btrim(coalesce(p_origin,'')));
  v_action text := upper(btrim(coalesce(p_action,'')));
  v_role text;
  v_permissions text[] := '{}'::text[];
  v_id uuid;
begin
  if v_origin not in ('CLIENT_TOKEN','ADMIN_UI','SYSTEM_JOB','PROVIDER_WEBHOOK') then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ORIGIN_INVALID';
  end if;
  if v_action = '' then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ACTION_REQUIRED';
  end if;
  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_origin = 'ADMIN_UI' then
    if p_admin_id is null or p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null
       or nullif(btrim(coalesce(p_request_id,'')),'') is null then
      raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
    end if;
    select role into v_role from public.admin_users where id = p_admin_id and is_active = true;
    if v_role is null then
      raise exception using errcode = 'P0001', message = 'ADMIN_ACCESS_DENIED';
    end if;
    v_permissions := public.service_admin_effective_permission_list(p_admin_id);
  elsif v_origin = 'CLIENT_TOKEN' and p_token_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_TOKEN_REQUIRED';
  elsif v_origin = 'PROVIDER_WEBHOOK' and nullif(btrim(coalesce(p_provider,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_PROVIDER_REQUIRED';
  end if;

  insert into public.appointment_authorship_events(
    appointment_id, origin, action, admin_user_id, actor_role, actor_permissions,
    appointment_access_token_id, provider, provider_event_id,
    before_json, after_json, reason, ip_address, user_agent, request_id, session_id
  ) values (
    p_appointment_id, v_origin, v_action, p_admin_id, v_role, v_permissions,
    p_token_id, nullif(btrim(coalesce(p_provider,'')),''), nullif(btrim(coalesce(p_provider_event_id,'')),''),
    p_before_json, p_after_json, nullif(btrim(coalesce(p_reason,'')),''), p_ip,
    nullif(btrim(coalesce(p_user_agent,'')),''), nullif(btrim(coalesce(p_request_id,'')),''),
    nullif(btrim(coalesce(p_session_id,'')),'')
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.service_admin_cancel_appointment_evidenced(
  p_appointment_id uuid,
  p_settlement_choice text,
  p_reason text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_admin_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  v_before := public.service_appointment_authorship_snapshot(p_appointment_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_result := public.service_admin_cancel_appointment(
    p_appointment_id, p_settlement_choice, p_reason, p_requested_at, p_change_origin, p_admin_id
  );
  v_after := public.service_appointment_authorship_snapshot(p_appointment_id);

  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      p_appointment_id, 'ADMIN_UI', 'APPOINTMENT_CANCELLED', p_admin_id, null,
      v_before, v_after, p_reason, p_ip, p_user_agent, p_request_id, p_session_id, null, null
    );
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_apply_reschedule_evidenced(
  p_policy_action_id uuid,
  p_admin_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  select appointment_id into v_appointment_id
  from public.appointment_policy_actions where id = p_policy_action_id;
  if v_appointment_id is null then
    raise exception using errcode = 'P0001', message = 'POLICY_ACTION_NOT_FOUND';
  end if;

  v_before := public.service_appointment_authorship_snapshot(v_appointment_id);
  v_result := public.service_admin_apply_reschedule(p_policy_action_id, p_admin_id);
  v_after := public.service_appointment_authorship_snapshot(v_appointment_id);

  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      v_appointment_id, 'ADMIN_UI', 'APPOINTMENT_RESCHEDULED', p_admin_id, null,
      v_before, v_after, null, p_ip, p_user_agent, p_request_id, p_session_id, null, null
    );
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_get_appointment_token_security_state(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_appointment_hash text;
  v_appointment_count integer := 0;
  v_locked_origins integer := 0;
  v_active_tokens integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_appointment_hash := encode(digest('appointment:'||p_appointment_id::text,'sha256'),'hex');
  select coalesce(max(request_count),0) into v_appointment_count
  from public.public_rate_limit_buckets
  where scope='TOKEN_VERIFY_APPOINTMENT' and key_hash=v_appointment_hash
    and window_started_at + interval '1 day' > clock_timestamp();

  with failed_ips as (
    select distinct host(ne.ip_address) ip
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id and e.event_type='VERIFY_FAILED'
    join public.appointment_token_network_evidence ne on ne.token_event_id=e.id
    where t.appointment_id=p_appointment_id and ne.ip_address is not null
  )
  select count(*)::integer into v_locked_origins
  from failed_ips f
  join public.public_rate_limit_buckets b
    on b.scope='TOKEN_VERIFY_ORIGIN'
   and b.key_hash=encode(digest('origin:'||f.ip,'sha256'),'hex')
   and b.window_started_at + interval '1 day' > clock_timestamp()
   and b.request_count >= 3;

  select count(*)::integer into v_active_tokens
  from public.appointment_access_tokens t
  where t.appointment_id=p_appointment_id
    and t.revoked_at is null and t.consumed_at is null
    and t.expires_at > clock_timestamp();

  return jsonb_build_object(
    'appointment_locked', v_appointment_count >= 3,
    'appointment_attempt_count', v_appointment_count,
    'locked_origin_count', v_locked_origins,
    'locked', (v_appointment_count >= 3 or v_locked_origins > 0),
    'active_token_count', v_active_tokens
  );
end;
$$;

create or replace function public.service_admin_unlock_appointment_token_verification(
  p_appointment_id uuid,
  p_admin_id uuid,
  p_reason text,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_appointment_hash text;
  v_before jsonb;
  v_after jsonb;
  v_origin record;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if v_reason is null then
    raise exception using errcode = 'P0001', message = 'UNLOCK_REASON_REQUIRED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  v_before := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);
  v_appointment_hash := encode(digest('appointment:'||p_appointment_id::text,'sha256'),'hex');

  delete from public.public_rate_limit_buckets
  where scope='TOKEN_VERIFY_APPOINTMENT' and key_hash=v_appointment_hash;

  for v_origin in
    select distinct host(ne.ip_address) ip
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id and e.event_type='VERIFY_FAILED'
    join public.appointment_token_network_evidence ne on ne.token_event_id=e.id
    where t.appointment_id=p_appointment_id and ne.ip_address is not null
  loop
    delete from public.public_rate_limit_buckets
    where scope='TOKEN_VERIFY_ORIGIN'
      and key_hash=encode(digest('origin:'||v_origin.ip,'sha256'),'hex');
  end loop;

  v_after := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);
  perform public.service_record_appointment_authorship_event(
    p_appointment_id, 'ADMIN_UI', 'TOKEN_VERIFICATION_UNLOCKED', p_admin_id, null,
    v_before, v_after, v_reason, p_ip, p_user_agent, p_request_id, p_session_id, null, null
  );
  return v_after;
end;
$$;

create or replace function public.service_admin_get_appointment_timeline(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_security jsonb;
  v_events jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.appointments where id=p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_security := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);

  with timeline as (
    select
      al.created_at occurred_at,
      'BUSINESS_AUDIT' source,
      al.id source_id,
      case
        when upper(coalesce(al.origin,'')) in ('ADMIN','OPERATION','ADMIN_UI') then 'ADMIN_UI'
        when upper(coalesce(al.origin,'')) in ('CLIENT','CLIENT_TOKEN') then 'CLIENT_TOKEN'
        when upper(coalesce(al.origin,'')) in ('MERCADO_PAGO','GOOGLE','PROVIDER','PROVIDER_WEBHOOK') then 'PROVIDER_WEBHOOK'
        else 'SYSTEM_JOB'
      end origin,
      al.action,
      al.admin_user_id,
      au.display_name actor_name,
      au.role actor_role,
      null::text[] actor_permissions,
      al.before_json,
      al.after_json,
      null::text reason,
      null::text ip_address,
      null::text user_agent,
      al.request_id::text request_id,
      null::text token_scope,
      null::text destination_masked,
      null::text provider,
      concat('Ação registrada: ', replace(al.action,'_',' ')) summary
    from public.audit_logs al
    left join public.admin_users au on au.id=al.admin_user_id
    where al.entity_id=p_appointment_id
       or al.entity_id in (select id from public.appointment_policy_actions where appointment_id=p_appointment_id)

    union all

    select
      ae.occurred_at,
      'AUTHORSHIP' source,
      ae.id source_id,
      ae.origin,
      ae.action,
      ae.admin_user_id,
      au.display_name actor_name,
      ae.actor_role,
      ae.actor_permissions,
      ae.before_json,
      ae.after_json,
      ae.reason,
      host(ae.ip_address) ip_address,
      ae.user_agent,
      ae.request_id,
      t.scope token_scope,
      t.destination_masked,
      ae.provider,
      case ae.action
        when 'APPOINTMENT_CANCELLED' then 'Reserva cancelada pela administração'
        when 'APPOINTMENT_RESCHEDULED' then 'Reserva remarcada pela administração'
        when 'TOKEN_VERIFICATION_UNLOCKED' then 'Bloqueio de verificação do link liberado pela administração'
        else concat('Evidência de autoria: ', replace(ae.action,'_',' '))
      end summary
    from public.appointment_authorship_events ae
    left join public.admin_users au on au.id=ae.admin_user_id
    left join public.appointment_access_tokens t on t.id=ae.appointment_access_token_id
    where ae.appointment_id=p_appointment_id

    union all

    select
      e.occurred_at,
      'TOKEN_EVIDENCE' source,
      e.id source_id,
      'CLIENT_TOKEN' origin,
      e.event_type action,
      null::uuid admin_user_id,
      null::text actor_name,
      null::text actor_role,
      null::text[] actor_permissions,
      null::jsonb before_json,
      e.metadata_json after_json,
      null::text reason,
      host(ne.ip_address) ip_address,
      ne.user_agent,
      e.request_id,
      t.scope token_scope,
      e.destination_masked,
      null::text provider,
      case e.event_type
        when 'ISSUED' then 'Link pessoal emitido'
        when 'ACCESS' then 'Link pessoal acessado'
        when 'VERIFY_FAILED' then 'Verificação adicional recusada'
        when 'VERIFIED' then 'E-mail cadastrado verificado'
        when 'ACTION_EXECUTED' then 'Ação do link executada'
        when 'CONSUMED' then 'Link consumido após uso'
        when 'REVOKED' then 'Link revogado após mudança da reserva'
        else concat('Evento do link: ', replace(e.event_type,'_',' '))
      end summary
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id
    left join lateral (
      select n.ip_address,n.user_agent
      from public.appointment_token_network_evidence n
      where n.token_event_id=e.id
      order by n.occurred_at desc limit 1
    ) ne on true
    where t.appointment_id=p_appointment_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'occurred_at', occurred_at,
    'source', source,
    'id', source_id,
    'origin', origin,
    'action', action,
    'admin_user_id', admin_user_id,
    'actor_name', actor_name,
    'actor_role', actor_role,
    'actor_permissions', actor_permissions,
    'before', before_json,
    'after', after_json,
    'reason', reason,
    'ip_address', ip_address,
    'user_agent', user_agent,
    'request_id', request_id,
    'token_scope', token_scope,
    'destination_masked', destination_masked,
    'provider', provider,
    'summary', summary
  ) order by occurred_at, source, source_id), '[]'::jsonb) into v_events
  from timeline;

  return jsonb_build_object('appointment_id',p_appointment_id,'security',v_security,'events',v_events);
end;
$$;

revoke all on function public.service_admin_effective_permission_list(uuid) from public, anon, authenticated;
revoke all on function public.service_appointment_authorship_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.service_record_appointment_authorship_event(uuid,text,text,uuid,uuid,jsonb,jsonb,text,inet,text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,timestamptz,text,uuid,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment_token_security_state(uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_unlock_appointment_token_verification(uuid,uuid,text,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment_timeline(uuid,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_effective_permission_list(uuid) to service_role;
grant execute on function public.service_appointment_authorship_snapshot(uuid) to service_role;
grant execute on function public.service_record_appointment_authorship_event(uuid,text,text,uuid,uuid,jsonb,jsonb,text,inet,text,text,text,text,text) to service_role;
grant execute on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,timestamptz,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_admin_get_appointment_token_security_state(uuid,uuid) to service_role;
grant execute on function public.service_admin_unlock_appointment_token_verification(uuid,uuid,text,inet,text,text,text) to service_role;
grant execute on function public.service_admin_get_appointment_timeline(uuid,uuid) to service_role;
