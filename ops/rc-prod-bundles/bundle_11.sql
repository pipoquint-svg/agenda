
-- BEGIN RC MIGRATION 20260826221000_birthday_email_delivery.sql
-- Issue #217 / V1.5 #257 — controlled birthday-email delivery.
-- Birthday coupons tied to an email remain inactive until the provider accepts the
-- idempotent message. This keeps the 30-day validity window anchored to delivery,
-- rather than to the birthday scheduler's calendar date.

alter table public.notification_delivery_logs
  drop constraint if exists notification_delivery_logs_status_check;
alter table public.notification_delivery_logs
  add constraint notification_delivery_logs_status_check
  check (status in ('PENDING','PROCESSING','SENT','FAILED','SKIPPED'));

create or replace function public.run_birthday_automation(
  p_run_date date default ((now() at time zone 'America/Sao_Paulo')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_setting public.birthday_automation_settings%rowtype;
  v_customer record;
  v_trigger_kind text;
  v_birthday_date date;
  v_trigger_date date;
  v_cycle_id uuid;
  v_coupon_id uuid;
  v_coupon_code text;
  v_template_id uuid;
  v_recipient_hash text;
  v_created_cycles integer := 0;
  v_created_coupons integer := 0;
  v_queued_messages integer := 0;
  v_skipped_existing integer := 0;
  v_service_count integer;
  v_year integer;
  v_is_leap boolean;
  v_feb28 date;
  v_mar01 date;
begin
  if p_run_date is null then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_RUN_DATE_REQUIRED';
  end if;

  v_year := extract(year from p_run_date)::integer;
  v_is_leap := (v_year % 400 = 0) or (v_year % 4 = 0 and v_year % 100 <> 0);

  for v_setting in
    select *
    from public.birthday_automation_settings
    where is_active
    order by operation_scope
  loop
    for v_customer in
      select distinct c.id, c.name, c.email, c.birth_date
      from public.customers c
      where c.birth_date is not null
        and exists (
          select 1
          from public.appointments a
          join public.services s on s.id = a.service_id
          where a.primary_customer_id = c.id
            and s.operation_scope = v_setting.operation_scope
        )
      order by c.id
    loop
      if extract(month from v_customer.birth_date)::integer = 2
         and extract(day from v_customer.birth_date)::integer = 29
         and not v_is_leap then
        v_feb28 := make_date(v_year, 2, 28);
        v_mar01 := make_date(v_year, 3, 1);
        if (v_setting.send_on_birthday and p_run_date in (v_feb28, v_mar01))
           or (v_setting.days_before is not null and v_setting.days_before > 0
               and p_run_date in (v_feb28 - v_setting.days_before, v_mar01 - v_setting.days_before)) then
          raise exception using errcode = 'P0001', message = 'BIRTHDAY_LEAP_DAY_POLICY_REQUIRED';
        end if;
        continue;
      end if;

      v_birthday_date := make_date(
        v_year,
        extract(month from v_customer.birth_date)::integer,
        extract(day from v_customer.birth_date)::integer
      );

      for v_trigger_kind in
        select trigger_kind
        from (
          values
            ('BIRTHDAY'::text, v_setting.send_on_birthday),
            ('BEFORE'::text, v_setting.days_before is not null and v_setting.days_before > 0)
        ) q(trigger_kind, enabled)
        where enabled
      loop
        v_trigger_date := case
          when v_trigger_kind = 'BEFORE' then v_birthday_date - v_setting.days_before
          else v_birthday_date
        end;

        if v_trigger_date <> p_run_date then
          continue;
        end if;

        v_cycle_id := null;
        insert into public.birthday_automation_cycles(
          operation_scope, customer_id, birthday_year, trigger_kind, target_date, message_status
        ) values (
          v_setting.operation_scope,
          v_customer.id,
          extract(year from v_birthday_date)::integer,
          v_trigger_kind,
          v_trigger_date,
          case when v_setting.send_message then 'PENDING' else null end
        )
        on conflict (operation_scope, customer_id, birthday_year, trigger_kind) do nothing
        returning id into v_cycle_id;

        if v_cycle_id is null then
          v_skipped_existing := v_skipped_existing + 1;
          continue;
        end if;

        v_created_cycles := v_created_cycles + 1;

        if v_setting.generate_coupon then
          select count(*) into v_service_count
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope;

          if v_service_count = 0 then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_COUPON_OPERATION_HAS_NO_ACTIVE_SERVICES';
          end if;

          v_coupon_code := upper(left(v_setting.coupon_prefix, 16))
            || '-' || extract(year from v_birthday_date)::integer::text
            || '-' || case when v_trigger_kind = 'BEFORE' then 'P' else 'D' end
            || '-' || upper(left(replace(v_customer.id::text, '-', ''), 8));

          insert into public.coupons(
            code, discount_type, discount_value, valid_from, valid_until, is_active,
            source, customer_id, max_uses, max_uses_per_customer, used_count
          ) values (
            v_coupon_code,
            v_setting.coupon_discount_type,
            v_setting.coupon_discount_value,
            case when v_setting.send_message then null else (p_run_date::timestamp at time zone 'America/Sao_Paulo') end,
            case when v_setting.send_message then null else ((p_run_date + v_setting.coupon_validity_days)::timestamp at time zone 'America/Sao_Paulo') end,
            not v_setting.send_message,
            'BIRTHDAY',
            v_customer.id,
            v_setting.coupon_max_uses,
            v_setting.coupon_max_uses_per_customer,
            0
          )
          returning id into v_coupon_id;

          insert into public.coupon_services(coupon_id, service_id)
          select v_coupon_id, s.id
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope
          on conflict do nothing;

          update public.birthday_automation_cycles
          set coupon_id = v_coupon_id, updated_at = now()
          where id = v_cycle_id;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_COUPON_CREATED', null,
            jsonb_build_object(
              'coupon_id', v_coupon_id,
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'birthday_year', extract(year from v_birthday_date)::integer,
              'trigger_kind', v_trigger_kind,
              'awaiting_delivery_activation', v_setting.send_message
            ),
            'SYSTEM'
          );

          v_created_coupons := v_created_coupons + 1;
        else
          v_coupon_id := null;
        end if;

        if v_setting.send_message then
          select t.id into v_template_id
          from public.notification_template_configs t
          where t.is_active
            and t.event_key = 'BIRTHDAY'
            and t.channel = 'EMAIL'
            and t.audience = 'CUSTOMER'
            and t.category_id is null
            and not exists (
              select 1 from public.notification_template_services nts where nts.template_id = t.id
            )
            and (t.operation_scope = v_setting.operation_scope or t.operation_scope is null)
          order by case when t.operation_scope = v_setting.operation_scope then 2 else 1 end desc,
                   t.updated_at desc,
                   t.id
          limit 1;

          if v_template_id is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_EMAIL_TEMPLATE_REQUIRED';
          end if;

          v_recipient_hash := case
            when nullif(lower(btrim(v_customer.email)), '') is null then null
            else encode(extensions.digest(lower(btrim(v_customer.email)), 'sha256'), 'hex')
          end;

          if v_recipient_hash is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_CUSTOMER_EMAIL_REQUIRED';
          end if;

          insert into public.notification_delivery_logs(
            template_id, event_key, channel, audience, customer_id, recipient_hash,
            status, idempotency_key, payload_snapshot
          ) values (
            v_template_id,
            'BIRTHDAY',
            'EMAIL',
            'CUSTOMER',
            v_customer.id,
            v_recipient_hash,
            'PENDING',
            'birthday:' || v_setting.operation_scope || ':' || v_customer.id::text || ':'
              || extract(year from v_birthday_date)::integer::text || ':' || v_trigger_kind,
            jsonb_build_object(
              'birthday_cycle_id', v_cycle_id,
              'operation_scope', v_setting.operation_scope,
              'trigger_kind', v_trigger_kind,
              'coupon_id', v_coupon_id
            )
          )
          on conflict (idempotency_key) do nothing;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_MESSAGE_QUEUED', null,
            jsonb_build_object(
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'template_id', v_template_id,
              'trigger_kind', v_trigger_kind
            ),
            'SYSTEM'
          );

          v_queued_messages := v_queued_messages + 1;
        end if;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object(
    'run_date', p_run_date,
    'created_cycles', v_created_cycles,
    'created_coupons', v_created_coupons,
    'queued_messages', v_queued_messages,
    'skipped_existing', v_skipped_existing
  );
end;
$$;

revoke all on function public.run_birthday_automation(date) from public, anon, authenticated;
grant execute on function public.run_birthday_automation(date) to service_role;

create or replace function public.claim_birthday_notification_deliveries(p_limit integer default 20)
returns table(
  id uuid,
  template_id uuid,
  customer_id uuid,
  idempotency_key text,
  payload_snapshot jsonb,
  attempt_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using errcode='P0001', message='BIRTHDAY_DELIVERY_LIMIT_INVALID';
  end if;

  return query
  with candidates as (
    select l.id
    from public.notification_delivery_logs l
    where l.event_key='BIRTHDAY'
      and l.channel='EMAIL'
      and l.audience='CUSTOMER'
      and l.attempt_count < 5
      and (
        l.status in ('PENDING','FAILED')
        or (l.status='PROCESSING' and l.updated_at < now() - interval '15 minutes')
      )
    order by l.created_at, l.id
    for update skip locked
    limit p_limit
  ), claimed as (
    update public.notification_delivery_logs l
    set status='PROCESSING',
        attempt_count=l.attempt_count+1,
        last_error_code=null,
        updated_at=now()
    from candidates c
    where l.id=c.id
    returning l.id,l.template_id,l.customer_id,l.idempotency_key,l.payload_snapshot,l.attempt_count
  )
  select c.id,c.template_id,c.customer_id,c.idempotency_key,c.payload_snapshot,c.attempt_count
  from claimed c
  order by c.id;
end;
$$;

create or replace function public.prepare_birthday_notification_delivery_window(p_log_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_log public.notification_delivery_logs%rowtype;
  v_scope text;
  v_validity integer;
  v_started timestamptz;
  v_expires timestamptz;
  v_payload jsonb;
begin
  select * into v_log
  from public.notification_delivery_logs
  where id=p_log_id and event_key='BIRTHDAY' and channel='EMAIL' and audience='CUSTOMER'
  for update;
  if not found then
    raise exception using errcode='P0001', message='BIRTHDAY_DELIVERY_LOG_NOT_FOUND';
  end if;

  v_payload := coalesce(v_log.payload_snapshot,'{}'::jsonb);
  if nullif(v_payload->>'delivery_window_started_at','') is not null
     and nullif(v_payload->>'coupon_expires_at','') is not null then
    return jsonb_build_object(
      'delivery_window_started_at', v_payload->>'delivery_window_started_at',
      'coupon_expires_at', v_payload->>'coupon_expires_at'
    );
  end if;

  v_scope := nullif(v_payload->>'operation_scope','');
  if v_scope is null then
    raise exception using errcode='P0001', message='BIRTHDAY_DELIVERY_OPERATION_SCOPE_MISSING';
  end if;
  select coupon_validity_days into v_validity
  from public.birthday_automation_settings
  where operation_scope=v_scope;
  if v_validity is null or v_validity < 1 then
    raise exception using errcode='P0001', message='BIRTHDAY_COUPON_VALIDITY_REQUIRED';
  end if;

  v_started := clock_timestamp();
  v_expires := v_started + make_interval(days => v_validity);
  update public.notification_delivery_logs
  set payload_snapshot = v_payload || jsonb_build_object(
        'delivery_window_started_at', v_started,
        'coupon_expires_at', v_expires
      ),
      updated_at=now()
  where id=p_log_id;

  return jsonb_build_object('delivery_window_started_at',v_started,'coupon_expires_at',v_expires);
end;
$$;

create or replace function public.finalize_birthday_notification_delivery(
  p_log_id uuid,
  p_provider_message_id text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_log public.notification_delivery_logs%rowtype;
  v_cycle_id uuid;
  v_coupon_id uuid;
  v_started timestamptz;
  v_expires timestamptz;
begin
  select * into v_log
  from public.notification_delivery_logs
  where id=p_log_id and event_key='BIRTHDAY' and channel='EMAIL' and audience='CUSTOMER'
  for update;
  if not found then
    raise exception using errcode='P0001', message='BIRTHDAY_DELIVERY_LOG_NOT_FOUND';
  end if;
  if v_log.status='SENT' then
    return;
  end if;

  v_cycle_id := nullif(v_log.payload_snapshot->>'birthday_cycle_id','')::uuid;
  v_coupon_id := nullif(v_log.payload_snapshot->>'coupon_id','')::uuid;
  v_started := nullif(v_log.payload_snapshot->>'delivery_window_started_at','')::timestamptz;
  v_expires := nullif(v_log.payload_snapshot->>'coupon_expires_at','')::timestamptz;
  if v_started is null or v_expires is null or v_expires <= v_started then
    raise exception using errcode='P0001', message='BIRTHDAY_DELIVERY_WINDOW_MISSING';
  end if;

  if v_coupon_id is not null then
    update public.coupons
    set is_active=true, valid_from=v_started, valid_until=v_expires, updated_at=now()
    where id=v_coupon_id and source='BIRTHDAY';
    if not found then
      raise exception using errcode='P0001', message='BIRTHDAY_COUPON_NOT_FOUND';
    end if;
  end if;

  update public.notification_delivery_logs
  set status='SENT', provider_message_id=nullif(btrim(coalesce(p_provider_message_id,'')),''),
      last_error_code=null, updated_at=now()
  where id=p_log_id;

  if v_cycle_id is not null then
    update public.birthday_automation_cycles
    set message_status='SENT', updated_at=now()
    where id=v_cycle_id;
  end if;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin)
  values('BIRTHDAY_AUTOMATION',coalesce(v_cycle_id,p_log_id),'BIRTHDAY_MESSAGE_SENT',null,
    jsonb_build_object('delivery_log_id',p_log_id,'coupon_id',v_coupon_id,'provider_message_recorded',nullif(btrim(coalesce(p_provider_message_id,'')),'') is not null),
    'SYSTEM');
end;
$$;

create or replace function public.fail_birthday_notification_delivery(
  p_log_id uuid,
  p_error_code text,
  p_preserve_window boolean default true
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_log public.notification_delivery_logs%rowtype;
  v_cycle_id uuid;
  v_payload jsonb;
begin
  select * into v_log
  from public.notification_delivery_logs
  where id=p_log_id and event_key='BIRTHDAY' and channel='EMAIL' and audience='CUSTOMER'
  for update;
  if not found then return; end if;
  if v_log.status='SENT' then return; end if;

  v_payload := coalesce(v_log.payload_snapshot,'{}'::jsonb);
  if not coalesce(p_preserve_window,true) then
    v_payload := v_payload - 'delivery_window_started_at' - 'coupon_expires_at';
  end if;
  v_cycle_id := nullif(v_payload->>'birthday_cycle_id','')::uuid;

  update public.notification_delivery_logs
  set status='FAILED',
      last_error_code=left(coalesce(nullif(btrim(p_error_code),''),'BIRTHDAY_EMAIL_DELIVERY_FAILED'),120),
      payload_snapshot=v_payload,
      updated_at=now()
  where id=p_log_id;

  if v_cycle_id is not null then
    update public.birthday_automation_cycles
    set message_status='FAILED', updated_at=now()
    where id=v_cycle_id;
  end if;
end;
$$;

revoke all on function public.claim_birthday_notification_deliveries(integer) from public, anon, authenticated;
revoke all on function public.prepare_birthday_notification_delivery_window(uuid) from public, anon, authenticated;
revoke all on function public.finalize_birthday_notification_delivery(uuid,text) from public, anon, authenticated;
revoke all on function public.fail_birthday_notification_delivery(uuid,text,boolean) from public, anon, authenticated;
grant execute on function public.claim_birthday_notification_deliveries(integer) to service_role;
grant execute on function public.prepare_birthday_notification_delivery_window(uuid) to service_role;
grant execute on function public.finalize_birthday_notification_delivery(uuid,text) to service_role;
grant execute on function public.fail_birthday_notification_delivery(uuid,text,boolean) to service_role;

comment on function public.claim_birthday_notification_deliveries(integer) is
  'Claims pending/failed birthday email evidence with SKIP LOCKED. Stale PROCESSING claims are recoverable after 15 minutes; max five attempts.';
comment on function public.finalize_birthday_notification_delivery(uuid,text) is
  'Atomically marks birthday email sent and activates its BIRTHDAY coupon for the delivery window stored before provider invocation.';
-- END RC MIGRATION 20260826221000_birthday_email_delivery.sql

-- BEGIN RC MIGRATION 20260826222500_birthday_coupon_locacao_scope.sql
-- Issue #217 — BlackSheep birthday coupons are commercially valid only for rentals.
-- Keep this as a database invariant so future active non-rental services cannot become
-- eligible by accident. The birthday campaign remains disabled by configuration.

create or replace function public.guard_birthday_coupon_service_scope()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_source text;
  v_service_type text;
begin
  select c.source, st.key
    into v_source, v_service_type
  from public.coupons c
  join public.services s on s.id = new.service_id
  left join public.service_type st on st.id = s.service_type_id
  where c.id = new.coupon_id;

  if v_source is distinct from 'BIRTHDAY' then
    return new;
  end if;

  -- BIRTHDAY coupons must never gain ENSAIO or an unclassified service.
  if v_service_type is distinct from 'LOCACAO' then
    return null;
  end if;

  return new;
end;
$$;

create or replace function public.assert_birthday_coupon_has_locacao_service()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.source = 'BIRTHDAY' and not exists (
    select 1
    from public.coupon_services cs
    join public.services s on s.id = cs.service_id
    join public.service_type st on st.id = s.service_type_id
    where cs.coupon_id = new.id
      and st.key = 'LOCACAO'
  ) then
    raise exception using errcode='P0001', message='BIRTHDAY_COUPON_REQUIRES_LOCACAO_SERVICE';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_birthday_coupon_service_scope() from public, anon, authenticated;
revoke all on function public.assert_birthday_coupon_has_locacao_service() from public, anon, authenticated;
grant execute on function public.guard_birthday_coupon_service_scope() to service_role;
grant execute on function public.assert_birthday_coupon_has_locacao_service() to service_role;

drop trigger if exists coupon_services_birthday_scope_guard on public.coupon_services;
create trigger coupon_services_birthday_scope_guard
before insert or update of coupon_id, service_id on public.coupon_services
for each row execute function public.guard_birthday_coupon_service_scope();

drop trigger if exists birthday_coupon_requires_locacao_service on public.coupons;
create constraint trigger birthday_coupon_requires_locacao_service
after insert or update on public.coupons
deferrable initially deferred
for each row execute function public.assert_birthday_coupon_has_locacao_service();

comment on function public.guard_birthday_coupon_service_scope() is
  'Database guard for #217: BIRTHDAY coupons can be linked only to services classified as service_type LOCACAO.';
comment on function public.assert_birthday_coupon_has_locacao_service() is
  'Deferred invariant for #217: every BIRTHDAY coupon must finish its transaction with at least one LOCACAO service.';
-- END RC MIGRATION 20260826222500_birthday_coupon_locacao_scope.sql

-- BEGIN RC MIGRATION 20260826223000_require_operation_scope_admin_boundary.sql
-- Harden the supported administrative boundary for operation_scope without
-- rewriting or classifying legacy/synthetic rows. The schema remains nullable
-- because Token Evidence and historical test fixtures are intentionally preserved;
-- supported admin mutations may no longer create a new NULL state.

create or replace function public.service_admin_update_operation_scope(
  p_service_id uuid,
  p_operation_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before text;
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope, ''))), '');
begin
  if v_scope is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_OPERATION_SCOPE_REQUIRED';
  end if;
  if v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode = 'P0001', message = 'SERVICE_OPERATION_SCOPE_INVALID';
  end if;

  select operation_scope into v_before
  from public.services
  where id = p_service_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_service_id = '97000000-0000-0000-0000-000000000010'::uuid then
    raise exception using errcode = 'P0001', message = 'TOKEN_EVIDENCE_OPERATION_SCOPE_IMMUTABLE';
  end if;

  if v_before is not distinct from v_scope then
    return jsonb_build_object(
      'service_id', p_service_id,
      'operation_scope', v_scope,
      'changed', false
    );
  end if;

  update public.services
  set operation_scope = v_scope,
      updated_at = now()
  where id = p_service_id;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_admin_id,
    'SERVICE',
    p_service_id,
    'OPERATION_SCOPE_CHANGED',
    jsonb_build_object('operation_scope', v_before),
    jsonb_build_object('operation_scope', v_scope),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', p_service_id,
    'operation_scope', v_scope,
    'changed', true
  );
end;
$$;

revoke all on function public.service_admin_update_operation_scope(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_operation_scope(uuid,text,uuid) to service_role;

comment on function public.service_admin_update_operation_scope(uuid,text,uuid) is
  'Sets mandatory BlackSheep/Sabrina service scope through the supported admin boundary. NULL is rejected; Token Evidence remains an immutable synthetic exception.';
-- END RC MIGRATION 20260826223000_require_operation_scope_admin_boundary.sql

-- BEGIN RC MIGRATION 20260826224000_snapshot_contract_v2_read_model.sql
-- V1.5 freeze gate — canonical read contract for immutable policy snapshots.
-- Historical snapshot rows and their policy_json are never rewritten. Consumers can
-- migrate to this read model while old V1 evidence remains byte-for-byte intact.

create or replace function public.canonical_change_policy_snapshot_contract(p_policy jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_source_schema text;
  v_notice_hours numeric;
  v_first_early numeric;
  v_first_late numeric;
  v_repeat numeric;
  v_cancel_late numeric;
  v_max_reschedules integer;
  v_status text;
begin
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    return jsonb_build_object(
      'contract_schema_version', 'CHANGE_POLICY_CONTRACT_V2',
      'source_schema_version', null,
      'normalization_status', 'INVALID_SOURCE'
    );
  end if;

  v_source_schema := coalesce(nullif(p_policy->>'snapshot_schema_version',''), 'CHANGE_POLICY_SNAPSHOT_V1');
  v_notice_hours := nullif(p_policy->>'notice_hours','')::numeric;

  -- V2 values win. V1 percentage/none mirrors are normalized only when their
  -- semantics are lossless. FIXED legacy penalties deliberately remain unsupported.
  v_first_early := case
    when nullif(p_policy->>'reschedule_first_early_percent','') is not null
      then (p_policy->>'reschedule_first_early_percent')::numeric
    when p_policy->>'reschedule_first_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_first_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_first_penalty_value','')::numeric
    else null
  end;

  v_first_late := case
    when nullif(p_policy->>'reschedule_first_late_percent','') is not null
      then (p_policy->>'reschedule_first_late_percent')::numeric
    when p_policy->>'reschedule_late_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_late_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_late_penalty_value','')::numeric
    else null
  end;

  v_repeat := case
    when nullif(p_policy->>'reschedule_repeat_percent','') is not null
      then (p_policy->>'reschedule_repeat_percent')::numeric
    when p_policy->>'reschedule_repeat_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_repeat_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_repeat_penalty_value','')::numeric
    else null
  end;

  v_cancel_late := case
    when nullif(p_policy->>'cancellation_late_percent','') is not null
      then (p_policy->>'cancellation_late_percent')::numeric
    when p_policy->>'cancellation_late_penalty_type' = 'NONE' then 0
    when p_policy->>'cancellation_late_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'cancellation_late_penalty_value','')::numeric
    else null
  end;

  v_max_reschedules := coalesce(nullif(p_policy->>'max_customer_reschedules','')::integer, 3);

  v_status := case
    when v_notice_hours is null
      or v_first_early is null
      or v_first_late is null
      or v_repeat is null
      or v_cancel_late is null
      then 'UNSUPPORTED_LEGACY_SHAPE'
    else 'CANONICAL'
  end;

  return jsonb_build_object(
    'contract_schema_version', 'CHANGE_POLICY_CONTRACT_V2',
    'source_schema_version', v_source_schema,
    'normalization_status', v_status,
    'notice_hours', v_notice_hours,
    'reschedule_first_early_percent', v_first_early,
    'reschedule_first_late_percent', v_first_late,
    'reschedule_repeat_percent', v_repeat,
    'cancellation_late_percent', v_cancel_late,
    'max_customer_reschedules', v_max_reschedules,
    'policy_timezone', coalesce(nullif(p_policy->>'policy_timezone',''), 'America/Sao_Paulo'),
    'notice_boundary_semantics', coalesce(
      nullif(p_policy->>'notice_boundary_semantics',''),
      'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
    )
  );
end;
$$;

revoke all on function public.canonical_change_policy_snapshot_contract(jsonb) from public, anon, authenticated;
grant execute on function public.canonical_change_policy_snapshot_contract(jsonb) to service_role;

create or replace view public.appointment_change_policy_snapshot_contract_v2
with (security_invoker = true)
as
select
  s.appointment_id,
  s.service_id,
  s.effective_at,
  s.source,
  s.captured_at,
  s.policy_json->>'snapshot_schema_version' as source_schema_version,
  public.canonical_change_policy_snapshot_contract(s.policy_json) as canonical_policy
from public.appointment_change_policy_snapshots s;

revoke all on table public.appointment_change_policy_snapshot_contract_v2 from public, anon, authenticated;
grant select on table public.appointment_change_policy_snapshot_contract_v2 to service_role;

comment on function public.canonical_change_policy_snapshot_contract(jsonb) is
  'Read-only compatibility adapter for immutable V1/V2 policy snapshots. Never mutates historical evidence; lossy legacy FIXED shapes are marked unsupported.';
comment on view public.appointment_change_policy_snapshot_contract_v2 is
  'Canonical V2 read contract over immutable appointment policy snapshots. Raw historical policy_json remains authoritative evidence in the source table.';
-- END RC MIGRATION 20260826224000_snapshot_contract_v2_read_model.sql

-- BEGIN RC MIGRATION 20260826225000_cover_birthday_notification_fks.sql
-- Performance follow-up from Supabase advisor.
-- Expand-only covering indexes for foreign keys introduced/used by birthday and notification flows.
-- No application behavior or authorization contract changes.

create index if not exists birthday_automation_cycles_coupon_id_idx
  on public.birthday_automation_cycles(coupon_id)
  where coupon_id is not null;

create index if not exists birthday_automation_cycles_customer_id_idx
  on public.birthday_automation_cycles(customer_id);

create index if not exists notification_delivery_logs_customer_id_idx
  on public.notification_delivery_logs(customer_id)
  where customer_id is not null;

create index if not exists notification_delivery_logs_employee_id_idx
  on public.notification_delivery_logs(employee_id)
  where employee_id is not null;

create index if not exists notification_delivery_logs_template_id_idx
  on public.notification_delivery_logs(template_id)
  where template_id is not null;
-- END RC MIGRATION 20260826225000_cover_birthday_notification_fks.sql

-- BEGIN RC MIGRATION 20260827001500_customer_birth_date_admin.sql
-- Issue #217 — canonical customer birth date management.
-- Adds a narrow, audited mutation for person customers only. No historical appointment snapshots are rewritten.

create or replace function public.service_admin_set_customer_birth_date(
  p_customer_id uuid,
  p_birth_date date,
  p_admin_id uuid
)
returns date
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer_type text;
  v_before date;
  v_after date;
begin
  if p_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_admin_id, 'CUSTOMERS_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select customer_type, birth_date
    into v_customer_type, v_before
  from public.customers
  where id = p_customer_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;
  if upper(coalesce(v_customer_type, '')) not in ('PERSON','PESSOA','INDIVIDUAL') then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_BIRTH_DATE_PERSON_ONLY';
  end if;
  if p_birth_date is not null and p_birth_date > current_date then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_BIRTH_DATE_FUTURE';
  end if;

  update public.customers
  set birth_date = p_birth_date,
      updated_at = now()
  where id = p_customer_id
  returning birth_date into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_admin_id,
    'CUSTOMER',
    p_customer_id,
    'BIRTH_DATE_CHANGED',
    jsonb_build_object('birth_date', v_before),
    jsonb_build_object('birth_date', v_after),
    'ADMIN'
  );

  return v_after;
end;
$$;

revoke all on function public.service_admin_set_customer_birth_date(uuid,date,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_customer_birth_date(uuid,date,uuid) to service_role;

comment on function public.service_admin_set_customer_birth_date(uuid,date,uuid) is
  'Audited canonical birth date mutation for person customers. Does not rewrite historical appointment snapshots or trigger birthday automation.';
-- END RC MIGRATION 20260827001500_customer_birth_date_admin.sql
