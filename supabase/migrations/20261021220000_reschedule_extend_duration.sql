-- Ampliar a duração pelo link de gerenciar reserva (decisão do usuário em 2026-10-21).
--   * a cliente escolhe uma duração igual ou maior que a contratada (nunca menor);
--   * o valor novo é a cotação da reserva inteira na nova duração, com a faixa de preço
--     por bloco que valer para ela; o acréscimo é esse valor menos o valor atual;
--   * no checkout ela paga 50% do acréscimo ou o acréscimo inteiro; o resto fica como saldo;
--   * cliente de pacote usa as horas do pacote (conciliação já existente);
--   * ampliar mantendo o mesmo início não tem multa e não conta como remarcação;
--   * aprovado o pagamento, a remarcação é aplicada na hora.
-- Também passa a aceitar o token do link de gerenciar reserva para pagar a diferença de
-- uma remarcação (antes era recusado com TOKEN_SCOPE_DENIED).
-- As funções service_get_public_payment_context e service_create_payment_intent_by_token
-- partem da definição que estava em produção (fora do repositório até aqui).

alter table public.appointment_policy_actions
  add column if not exists requested_duration_blocks integer,
  add column if not exists extension_increment numeric(12,2),
  add column if not exists extension_full_target numeric(12,2),
  add column if not exists is_duration_extension_only boolean not null default false;

comment on column public.appointment_policy_actions.extension_full_target is
  'Ampliação de duração: cobertura do contrato com o acréscimo inteiro pago (opção integral).';
comment on column public.appointment_policy_actions.is_duration_extension_only is
  'Ampliação mantendo o mesmo início: sem multa e fora da contagem de remarcações da cliente.';

-- ===== Base de produção =====
-- Definições que estavam em produção para a remarcação pela cliente, trazidas sem
-- alteração para o repositório (no banco de produção isto não muda nada; no CI, os
-- testes passam a rodar contra o mesmo código). As permissões repetem as de produção.

CREATE OR REPLACE FUNCTION public.appointment_contract_coverage_amount(p_appointment_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$ select round(greatest(public.appointment_net_contract_settled_amount(p_appointment_id)+coalesce((select sum(cbm.amount) from public.customer_balance_movements cbm where cbm.appointment_id=p_appointment_id and cbm.movement_type='APPLY_TO_APPOINTMENT' and cbm.direction='DEBIT'),0)-coalesce((select sum(acs.penalty_retained) from public.appointment_change_settlements acs join public.appointment_policy_actions apa on apa.id=acs.policy_action_id where acs.appointment_id=p_appointment_id and acs.action_type='RESCHEDULE' and apa.status='APPLIED'),0),0),2)::numeric(12,2); $function$;

CREATE OR REPLACE FUNCTION public.create_checkout_hold_for_reschedule(p_appointment_id uuid, p_requested_start_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_discount public.appointment_discounts%rowtype;
  v_has_discount boolean := false;
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[]:='{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
  v_contracted_minutes integer;
  v_range record;
  v_own_ranges tstzmultirange;
  v_delta_ranges tstzmultirange;
  v_segment tstzrange;
  v_pre_discount_value numeric(12,2) := 0;
  v_discount_amount numeric(12,2) := 0;
  v_commercial_value numeric(12,2) := 0;
  v_pricing_version text;
begin
  perform public.expire_due_checkout_holds();

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id and deleted_at is null;

  if not found or v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  select *
    into v_discount
  from public.appointment_discounts
  where appointment_id=p_appointment_id;
  v_has_discount := found;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity)
      order by ae.extra_id
    ),
    '[]'::jsonb
  )
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  v_contracted_minutes:=public.resolve_service_contracted_minutes(
    v_appointment.service_id,
    v_appointment.duration_blocks
  );

  select timezone into v_timezone
  from public.operation_settings
  where id=1;

  v_requested_local_date:=(p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date,
      null,
      p_appointment_id
    )
    union all
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date+1,
      null,
      p_appointment_id
    )
  ) s
  where s.slot_start_at=p_requested_start_at
    and s.core_start_at is distinct from v_appointment.core_start_at
    and not exists(
      select 1
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        s.core_start_at,
        v_appointment.duration_blocks
      ) rr
      where not public.google_resource_sync_is_ready(rr.resource_id,600)
    )
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end if;

  -- A remarcação parte do preço atual do novo horário, mas preserva a
  -- condição comercial já contratada. O desconto é um snapshot da reserva,
  -- não uma nova aplicação/consumo de cupom.
  v_quote:=public.calculate_booking_quote_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_appointment.duration_blocks,
    v_extras,
    v_appointment.people_count,
    v_slot.core_start_at,
    null
  );

  v_pre_discount_value:=round(
    greatest(coalesce((v_quote->>'commercial_value')::numeric,0),0),
    2
  );
  v_commercial_value:=v_pre_discount_value;
  v_pricing_version:=coalesce(v_quote->>'pricing_version','');

  if v_has_discount then
    if v_discount.discount_type_snapshot='PERCENT' then
      v_discount_amount:=round(
        public.coupon_discount_amount('PERCENT',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>'extras_total')::numeric,0)),
        2
      );
    elsif v_discount.discount_type_snapshot='FIXED' then
      v_discount_amount:=round(
        public.coupon_discount_amount('FIXED',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>'extras_total')::numeric,0)),
        2
      );
    else
      raise exception using errcode='P0001',message='APPOINTMENT_DISCOUNT_SNAPSHOT_INVALID';
    end if;

    v_discount_amount:=round(
      least(greatest(v_discount_amount,0),v_pre_discount_value),
      2
    );
    v_commercial_value:=round(
      greatest(v_pre_discount_value-v_discount_amount,0),
      2
    );

    v_pricing_version:=md5(concat_ws(
      '|',
      v_pricing_version,
      'RESCHEDULE_DISCOUNT_SNAPSHOT_V1',
      coalesce(v_discount.code_snapshot,''),
      v_discount.discount_type_snapshot,
      v_discount.discount_value_snapshot::text
    ));

    v_quote:=v_quote || jsonb_build_object(
      'coupon_code',v_discount.code_snapshot,
      'coupon_discount',v_discount_amount,
      'discount_amount',v_discount_amount,
      'pre_discount_value',v_pre_discount_value,
      'commercial_value',v_commercial_value,
      'total_amount',v_commercial_value,
      'discount_source','APPOINTMENT_SNAPSHOT',
      'discount_snapshot_type',v_discount.discount_type_snapshot,
      'discount_snapshot_value',v_discount.discount_value_snapshot,
      'pricing_version',v_pricing_version
    );
  end if;

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_appointment.service_id,
    v_extras,
    v_slot.core_start_at,
    v_appointment.duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001',message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(s.checkout_hold_minutes,os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s
  cross join public.operation_settings os
  where s.id=v_appointment.service_id and os.id=1;

  v_expires_at:=coalesce(
    nullif(current_setting('agenda.test_now',true),'')::timestamptz,
    now()
  )+make_interval(mins=>v_hold_minutes);

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_token_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  v_selection_hash:=md5(concat_ws(
    '|',
    'RESCHEDULE',
    p_appointment_id::text,
    v_appointment.service_id::text,
    v_appointment.service_employee_id::text,
    coalesce(v_appointment.duration_blocks::text,'FIXED'),
    v_extras::text,
    v_appointment.people_count::text,
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
    v_pricing_version
  ));

  insert into public.checkout_holds(
    public_token_hash,
    service_id,
    service_employee_id,
    selection_hash,
    people_count,
    requested_start_at,
    requested_end_at,
    core_start_at,
    core_end_at,
    pre_service_minutes,
    post_service_minutes,
    schedule_profile,
    status,
    expires_at,
    extra_selections,
    commercial_value,
    pricing_version,
    duration_minutes,
    resource_ids,
    duration_blocks,
    contracted_minutes,
    primary_customer_id,
    quote_snapshot,
    applied_coupon_id,
    coupon_code_snapshot,
    coupon_discount,
    pre_discount_value
  ) values(
    v_token_hash,
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_selection_hash,
    v_appointment.people_count,
    v_slot.slot_start_at,
    v_slot.slot_end_at,
    v_slot.core_start_at,
    v_slot.core_end_at,
    v_slot.pre_service_minutes,
    v_slot.post_service_minutes,
    v_quote->'schedule_profile',
    'ACTIVE',
    v_expires_at,
    v_extras,
    v_commercial_value,
    v_pricing_version,
    v_slot.duration_minutes,
    v_resource_ids,
    v_appointment.duration_blocks,
    v_contracted_minutes,
    v_appointment.primary_customer_id,
    v_quote,
    case when v_has_discount then v_discount.coupon_id else null end,
    case when v_has_discount then v_discount.code_snapshot else null end,
    case when v_has_discount then v_discount_amount else 0 end,
    case when v_has_discount then v_pre_discount_value else null end
  )
  returning id into v_hold_id;

  -- A reserva atual já protege a parte sobreposta. O hold de remarcação segura
  -- apenas os trechos NOVOS fora da ocupação atual, evitando conflito consigo mesma.
  begin
    for v_range in
      select *
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        v_slot.core_start_at,
        v_appointment.duration_blocks
      )
    loop
      select coalesce(range_agg(ra.occupied_range),'{}'::tstzmultirange)
      into v_own_ranges
      from public.resource_allocations ra
      where ra.appointment_id=p_appointment_id
        and ra.resource_id=v_range.resource_id
        and ra.allocation_type='APPOINTMENT'
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');

      v_delta_ranges:=tstzmultirange(v_range.occupied_range)-v_own_ranges;

      for v_segment in select unnest(v_delta_ranges)
      loop
        insert into public.resource_allocations(
          resource_id,
          checkout_hold_id,
          allocation_type,
          status,
          occupied_range
        )
        values(
          v_range.resource_id,
          v_hold_id,
          'CHECKOUT_HOLD',
          'HELD',
          v_segment
        );
      end loop;
    end loop;
  exception
    when exclusion_violation then
      update public.checkout_holds
      set status='INVALIDATED',updated_at=now()
      where id=v_hold_id;

      raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token',v_raw_token,
    'checkout_hold_id',v_hold_id,
    'status','ACTIVE',
    'expires_at',v_expires_at,
    'slot_start_at',v_slot.slot_start_at,
    'slot_end_at',v_slot.slot_end_at,
    'core_start_at',v_slot.core_start_at,
    'core_end_at',v_slot.core_end_at,
    'pre_service_minutes',v_slot.pre_service_minutes,
    'post_service_minutes',v_slot.post_service_minutes,
    'commercial_value',v_commercial_value,
    'duration_minutes',v_slot.duration_minutes,
    'duration_blocks',v_appointment.duration_blocks,
    'contracted_minutes',v_contracted_minutes,
    'pricing_version',v_pricing_version
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_appointment_reschedule_limit(p_appointment_id uuid, p_change_origin text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$ declare v_limit integer; v_count integer; begin if p_change_origin not in('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if; if p_change_origin='OPERATION' then return; end if; select max_customer_reschedules into v_limit from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id; if v_limit is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if; v_count:=public.appointment_client_reschedule_count(p_appointment_id); if v_count>=v_limit then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED',detail=jsonb_build_object('limit',v_limit,'count',v_count)::text; end if; end; $function$;

CREATE OR REPLACE FUNCTION public.service_admin_apply_reschedule(p_policy_action_id uuid, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_package_reconciliation jsonb;
  v_coverage numeric(12,2);
  v_after_penalty numeric(12,2);
  v_outstanding numeric(12,2);
  v_customer_after_penalty numeric(12,2);
  v_new_version integer;
  v_old_start timestamptz;
  v_old_end timestamptz;
  v_old_value numeric(12,2);
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' then raise exception using errcode='P0001',message='INVALID_RESCHEDULE_ACTION'; end if;
  if v_action.status='APPLIED' then
    select * into v_appointment from public.appointments where id=v_action.appointment_id;
    return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','APPLIED','appointment_version',v_appointment.version,'already_applied',true);
  end if;
  if v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_APPLICABLE'; end if;

  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  select * into v_appointment from public.appointments where id=v_action.appointment_id for update;
  if not found or v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED'; end if;
  if v_hold.service_id<>v_appointment.service_id or v_hold.service_employee_id<>v_appointment.service_employee_id then raise exception using errcode='P0001',message='RESCHEDULE_HOLD_MISMATCH'; end if;

  v_coverage:=public.appointment_contract_coverage_amount(v_appointment.id);
  v_after_penalty:=round(greatest(v_coverage-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.confirmation_target_amount-v_after_penalty,0),2);
  if v_outstanding>0 then
    update public.appointment_policy_actions set status='AWAITING_DIFFERENCE_PAYMENT',difference_due=v_outstanding,updated_at=now() where id=v_action.id;
    raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_PAYMENT_REQUIRED',detail=jsonb_build_object('outstanding',v_outstanding)::text;
  end if;

  v_package_reconciliation:=public.service_reconcile_reschedule_package(v_appointment.id,v_hold.id,p_admin_id);
  v_old_start:=v_appointment.start_at; v_old_end:=v_appointment.end_at; v_old_value:=v_appointment.commercial_value;
  v_customer_after_penalty:=round(greatest(public.appointment_customer_funds_amount(v_appointment.id)-v_settlement.penalty_retained,0),2);

  -- Troca atômica: a alocação atual e os segmentos temporários do hold são
  -- liberados dentro da mesma transação; em seguida reconstruímos a ocupação
  -- COMPLETA do novo horário. A exclusion constraint continua protegendo contra concorrência.
  update public.resource_allocations set status='RELEASED',updated_at=now()
  where appointment_id=v_appointment.id and allocation_type='APPOINTMENT' and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');
  update public.resource_allocations set status='RELEASED',updated_at=now()
  where checkout_hold_id=v_hold.id and allocation_type='CHECKOUT_HOLD' and status='HELD';

  insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
  select r.resource_id,v_appointment.id,'APPOINTMENT','CONFIRMED',r.occupied_range
  from public.calculate_booking_resource_ranges_for_duration(v_hold.service_id,v_hold.extra_selections,v_hold.core_start_at,v_hold.duration_blocks) r;

  update public.appointments set
    start_at=v_hold.requested_start_at,end_at=v_hold.requested_end_at,core_start_at=v_hold.core_start_at,core_end_at=v_hold.core_end_at,
    pre_service_minutes=v_hold.pre_service_minutes,post_service_minutes=v_hold.post_service_minutes,schedule_profile_snapshot=v_hold.schedule_profile,
    duration_minutes=v_hold.duration_minutes,duration_blocks=v_hold.duration_blocks,contracted_minutes=v_hold.contracted_minutes,
    commercial_value=v_settlement.new_contract_value,coupon_discount=case when v_hold.quote_snapshot->>'discount_source'='APPOINTMENT_SNAPSHOT' then round(coalesce(v_hold.coupon_discount,0),2) else coupon_discount end,version=version+1,updated_at=now()
  where id=v_appointment.id returning version into v_new_version;

  if v_hold.quote_snapshot->>'discount_source'='APPOINTMENT_SNAPSHOT' then
    update public.appointment_discounts
    set calculated_discount_amount=round(coalesce(v_hold.coupon_discount,0),2)
    where appointment_id=v_appointment.id;
  end if;

  update public.checkout_holds set status='PROMOTED',promoted_appointment_id=v_appointment.id,updated_at=now() where id=v_hold.id;
  update public.appointment_policy_actions set status='APPLIED',difference_due=0,updated_at=now() where id=v_action.id;
  perform public.refresh_appointment_financial_status(v_appointment.id);

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values('GOOGLE_APPOINTMENT_SYNC','APPOINTMENT',v_appointment.id,v_new_version,jsonb_build_object('reason','APPOINTMENT_RESCHEDULED'),
    'google-appointment-sync:'||v_appointment.id::text||':'||v_new_version::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_RESCHEDULED',
    jsonb_build_object('start_at',v_old_start,'end_at',v_old_end,'commercial_value',v_old_value,'version',v_appointment.version),
    jsonb_build_object('start_at',v_hold.requested_start_at,'end_at',v_hold.requested_end_at,'commercial_value',v_settlement.new_contract_value,
      'version',v_new_version,'policy_action_id',v_action.id,'change_origin',v_action.change_origin,'payment_commitment_percent',v_settlement.payment_commitment_percent,
      'confirmation_target_amount',v_settlement.confirmation_target_amount,'penalty_retained',v_settlement.penalty_retained,
      'excess_amount',greatest(v_customer_after_penalty-v_settlement.new_contract_value,0),'package_reconciliation',v_package_reconciliation),
    case when v_action.change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action.id,'appointment_id',v_appointment.id,'status','APPLIED','old_start_at',v_old_start,
    'new_start_at',v_hold.requested_start_at,'new_end_at',v_hold.requested_end_at,'old_contract_value',v_old_value,
    'new_contract_value',v_settlement.new_contract_value,'payment_commitment_percent',v_settlement.payment_commitment_percent,
    'confirmation_target_amount',v_settlement.confirmation_target_amount,'penalty_retained',v_settlement.penalty_retained,
    'difference_due',0,'excess_amount',greatest(v_customer_after_penalty-v_settlement.new_contract_value,0),
    'appointment_version',v_new_version,'google_sync_enqueued',true,'already_applied',false,'package_reconciliation',v_package_reconciliation
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold_standard(p_appointment_id uuid, p_requested_start_at timestamp with time zone, p_requested_at timestamp with time zone, p_change_origin text, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb;
  v_hold jsonb;
  v_package_quote jsonb;
  v_hold_row public.checkout_holds%rowtype;
  v_hold_id uuid;
  v_action_id uuid;
  v_action_status text;
  v_previous record;
  v_settlement_id uuid;
  v_new_contract_value numeric(12,2);
  v_package_cash_due numeric(12,2);
begin
  if p_requested_start_at is null or p_requested_at is null then raise exception using errcode='P0001',message='RESCHEDULE_TIME_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  perform public.enforce_appointment_reschedule_limit(p_appointment_id,p_change_origin);

  for v_previous in
    select id,reschedule_checkout_hold_id from public.appointment_policy_actions
    where appointment_id=p_appointment_id and action_type='RESCHEDULE' and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') for update
  loop
    if v_previous.reschedule_checkout_hold_id is not null then
      update public.resource_allocations set status='RELEASED',updated_at=now()
      where checkout_hold_id=v_previous.reschedule_checkout_hold_id and allocation_type='CHECKOUT_HOLD' and status='HELD';
      update public.checkout_holds set status='INVALIDATED',updated_at=now()
      where id=v_previous.reschedule_checkout_hold_id and status='ACTIVE';
    end if;
    update public.appointment_policy_actions set status='VOIDED',updated_at=now() where id=v_previous.id;
  end loop;

  v_hold:=public.create_checkout_hold_for_reschedule(p_appointment_id,p_requested_start_at);
  v_hold_id:=(v_hold->>'checkout_hold_id')::uuid;
  select * into v_hold_row from public.checkout_holds where id=v_hold_id;

  v_package_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,v_hold_id);
  if coalesce((v_package_quote->>'uses_package')::boolean,false) then
    select apu.cash_due into v_package_cash_due from public.appointment_package_usage apu
    where apu.appointment_id=p_appointment_id and apu.reversal_movement_id is null;
    if v_package_cash_due is null then raise exception using errcode='P0001',message='RESCHEDULE_PACKAGE_USAGE_MISSING'; end if;
    v_new_contract_value:=round(v_package_cash_due,2);
  else
    v_new_contract_value:=round(v_hold_row.commercial_value,2);
  end if;

  v_preview:=public.calculate_reservation_change(p_appointment_id,'RESCHEDULE',p_requested_at,p_change_origin,v_new_contract_value);
  if coalesce((v_preview->>'customer_reschedule_limit_reached')::boolean,false) then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED'; end if;
  v_action_status:=case when coalesce((v_preview->>'difference_due')::numeric,0)>0 then 'AWAITING_DIFFERENCE_PAYMENT' else 'PREVIEW' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,hours_before_start,notice_hours_snapshot,
    is_inside_notice_window,prior_customer_reschedules,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,
    refundable_amount,reschedule_checkout_hold_id,created_by_admin_id,change_origin,policy_schema_version,contract_applied_before,excess_before,
    applicable_amount,excess_amount,difference_due,refund_due
  ) values(
    p_appointment_id,'RESCHEDULE',v_action_status,p_requested_at,v_appointment.start_at,v_hold_row.requested_start_at,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'customer_funds_before')::numeric,
    'PERCENT'::public.change_penalty_type,(v_preview->>'penalty_percent')::numeric,(v_preview->>'penalty_retained')::numeric,0,v_hold_id,p_admin_id,
    p_change_origin,v_preview->>'snapshot_schema_version',(v_preview->>'contract_applied_before')::numeric,(v_preview->>'excess_before')::numeric,
    (v_preview->>'applicable_amount')::numeric,(v_preview->>'excess_amount')::numeric,(v_preview->>'difference_due')::numeric,0
  ) returning id into v_action_id;

  v_settlement_id:=public.record_appointment_change_settlement(v_action_id,v_preview);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'RESCHEDULE_PREVIEW_CREATED',jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'change_origin',p_change_origin,
    'penalty_retained',v_preview->'penalty_retained','applicable_amount',v_preview->'applicable_amount',
    'new_contract_value',v_new_contract_value,'difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'package_reconciliation',v_package_quote
  ),case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_action_status,'appointment_id',p_appointment_id,
    'change_origin',p_change_origin,'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold_row.expires_at,'slot_start_at',v_hold_row.requested_start_at,
      'slot_end_at',v_hold_row.requested_end_at,'core_start_at',v_hold_row.core_start_at,'core_end_at',v_hold_row.core_end_at),
    'contract_value',v_preview->'contract_value','new_contract_value',v_new_contract_value,'payment_commitment_percent',v_preview->'payment_commitment_percent',
    'confirmation_target_amount',v_preview->'confirmation_target_amount','penalty_percent',v_preview->'penalty_percent','penalty_retained',v_preview->'penalty_retained',
    'applicable_amount',v_preview->'applicable_amount','difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'prior_customer_reschedules',v_preview->'prior_customer_reschedules','max_customer_reschedules',v_preview->'max_customer_reschedules',
    'package_reconciliation',v_package_quote
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold(p_appointment_id uuid, p_requested_start_at timestamp with time zone, p_requested_at timestamp with time zone, p_change_origin text, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result jsonb;
  v_action_id uuid;
  v_hold_id uuid;
  v_status text;
  v_payment_hold_minutes integer;
  v_new_expires_at timestamptz;
begin
  v_result := public.service_admin_create_reschedule_hold_standard(
    p_appointment_id,
    p_requested_start_at,
    p_requested_at,
    p_change_origin,
    p_admin_id
  );

  v_status := v_result->>'policy_action_status';

  if v_status='AWAITING_DIFFERENCE_PAYMENT' then
    v_action_id := (v_result->>'policy_action_id')::uuid;
    v_hold_id := (v_result->'new_slot'->>'checkout_hold_id')::uuid;

    select coalesce(
      s.payment_hold_minutes,
      os.payment_hold_minutes,
      30
    )
    into v_payment_hold_minutes
    from public.appointments a
    join public.services s on s.id=a.service_id
    cross join public.operation_settings os
    where a.id=p_appointment_id and os.id=1;

    v_new_expires_at := clock_timestamp()+make_interval(mins=>greatest(coalesce(v_payment_hold_minutes,30),30));

    update public.checkout_holds
    set expires_at=v_new_expires_at,
        updated_at=now()
    where id=v_hold_id
      and status='ACTIVE';

    v_result := jsonb_set(
      v_result,
      '{new_slot,expires_at}',
      to_jsonb(v_new_expires_at),
      true
    );

    insert into public.audit_logs(
      admin_user_id,entity_type,entity_id,action,after_json,origin
    )
    values(
      p_admin_id,
      'APPOINTMENT',
      p_appointment_id,
      'RESCHEDULE_PAYMENT_HOLD_EXTENDED',
      jsonb_build_object(
        'policy_action_id',v_action_id,
        'checkout_hold_id',v_hold_id,
        'expires_at',v_new_expires_at,
        'minutes',greatest(coalesce(v_payment_hold_minutes,30),30)
      ),
      case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end
    );
  end if;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold(uuid, timestamp with time zone, timestamp with time zone, uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_list_reschedule_slots(p_appointment_id uuid, p_local_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_extras jsonb;
  v_timezone text;
  v_available bigint;
  v_old_charged bigint;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_required bigint;
  v_surcharge bigint;
  v_delta bigint;
  v_special boolean;
  v_result jsonb:='[]'::jsonb;
  r record;
begin
  if p_local_date is null then raise exception using errcode='P0001',message='RESCHEDULE_DATE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null;
  if found then
    select * into v_package from public.hour_packages where id=v_usage.hour_package_id;
    select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id;
    v_old_charged:=v_usage.charged_seconds;
    select timezone into v_timezone from public.operation_settings where id=1;
  end if;

  for r in
    select s.*
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
      v_extras,v_appointment.people_count,p_local_date,null,p_appointment_id
    ) s
    where s.core_start_at is distinct from v_appointment.core_start_at
      and not exists(
        select 1 from public.calculate_booking_resource_ranges_for_duration(
          v_appointment.service_id,v_extras,s.core_start_at,v_appointment.duration_blocks
        ) rr where not public.google_resource_sync_is_ready(rr.resource_id,600)
      )
  loop
    if v_usage.id is not null then
      if v_package.status<>'ACTIVE' or r.slot_start_at<v_package.valid_from or r.slot_start_at>=v_package.valid_until
        or not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id)
      then continue; end if;
      v_local_start:=r.slot_start_at at time zone v_timezone;
      v_local_end:=r.slot_end_at at time zone v_timezone;
      v_special:=extract(dow from v_local_start)::integer in(0,6)
        or v_local_start::date<>v_local_end::date
        or v_local_start::time<v_package.standard_start_local_time
        or v_local_end::time>v_package.standard_end_local_time;
      v_required:=r.duration_minutes::bigint*60;
      v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end;
      v_delta:=(v_required+v_surcharge)-v_old_charged;
      if v_delta>0 and coalesce(v_available,0)<v_delta then continue; end if;
    end if;

    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'slot_start_at',r.slot_start_at,'slot_end_at',r.slot_end_at,
      'core_start_at',r.core_start_at,'core_end_at',r.core_end_at,
      'pre_service_minutes',r.pre_service_minutes,'post_service_minutes',r.post_service_minutes,
      'duration_minutes',r.duration_minutes,
      'package_delta_seconds',case when v_usage.id is null then 0 else v_delta end
    ));
  end loop;
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_client_apply_reschedule_evidenced(p_token_id uuid, p_policy_action_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_session_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_token public.appointment_access_tokens%rowtype; v_action public.appointment_policy_actions%rowtype; v_requirements jsonb; v_requires_email boolean; v_verified boolean:=false; v_before jsonb; v_after jsonb; v_result jsonb; v_request_id text:=nullif(left(btrim(coalesce(p_request_id,'')),200),'');
begin
 if p_token_id is null or p_policy_action_id is null then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID'; end if; if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or v_request_id is null then raise exception using errcode='P0001',message='AUTHORSHIP_CLIENT_EVIDENCE_REQUIRED'; end if;
 select * into v_token from public.appointment_access_tokens where id=p_token_id for update; if not found or v_token.scope<>'RESCHEDULE' or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at is null or v_token.expires_at<=clock_timestamp() then raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID'; end if; select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update; if not found or v_action.appointment_id<>v_token.appointment_id then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID'; end if;
 v_requirements:=public.service_client_reschedule_requirements(v_token.id,v_action.id); v_requires_email:=coalesce((v_requirements->>'requires_email_verification')::boolean,false); if v_requires_email then select exists(select 1 from public.appointment_token_events e where e.appointment_access_token_id=v_token.id and e.event_type='VERIFIED' and e.request_id=v_request_id) into v_verified; if not v_verified then raise exception using errcode='P0001',message='RESCHEDULE_EMAIL_VERIFICATION_REQUIRED'; end if; end if;
 v_before:=public.service_appointment_authorship_snapshot(v_token.appointment_id); perform public.service_consume_appointment_action_token(v_token.id,'RESCHEDULE_CONFIRMED',p_ip,p_user_agent,v_request_id,jsonb_build_object('financial_action',v_requires_email,'verification_method',case when v_requires_email then 'REGISTERED_EMAIL' else 'TOKEN_ONLY' end,'policy_action_id',v_action.id)); v_result:=public.service_admin_apply_reschedule(v_action.id,null); v_after:=public.service_appointment_authorship_snapshot(v_token.appointment_id);
 if v_before is distinct from v_after then perform public.service_record_appointment_authorship_event(v_token.appointment_id,'CLIENT_TOKEN','APPOINTMENT_RESCHEDULED',null,v_token.id,v_before,v_after,null,p_ip,p_user_agent,v_request_id,p_session_id,null,null); end if; return v_result||jsonb_build_object('token_consumed',true,'required_email_verification',v_requires_email);
end; $function$;

CREATE OR REPLACE FUNCTION public.service_client_reschedule_requirements(p_token_id uuid, p_policy_action_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_current_coverage numeric(12,2);
  v_coverage_after_penalty numeric(12,2);
  v_outstanding numeric(12,2);
  v_financial boolean;
begin
  select * into v_token from public.appointment_access_tokens where id=p_token_id;
  if not found or v_token.scope<>'RESCHEDULE' or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at is null or v_token.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=v_token.appointment_id and deleted_at is null;
  if not found or v_appointment.status<>'CONFIRMED' or v_appointment.start_at<=clock_timestamp() or v_token.expires_at<>v_appointment.start_at then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id;
  if not found or v_action.appointment_id<>v_appointment.id or v_action.action_type<>'RESCHEDULE' or v_action.change_origin<>'CLIENT' or v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;

  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED';
  end if;

  -- Regra autoritativa: uma remarcação só exige pagamento adicional quando a
  -- cobertura atual, após eventual multa, fica abaixo da META DE CONFIRMAÇÃO
  -- do novo contrato. Não se exige quitação integral quando a reserva original
  -- foi confirmada legitimamente com sinal/percentual.
  v_current_coverage:=round(public.appointment_contract_coverage_amount(v_appointment.id),2);
  v_coverage_after_penalty:=round(greatest(v_current_coverage-coalesce(v_settlement.penalty_retained,0),0),2);
  v_outstanding:=round(greatest(coalesce(v_settlement.confirmation_target_amount,0)-v_coverage_after_penalty,0),2);
  v_financial:=coalesce(v_settlement.penalty_retained,0)>0.005
    or abs(coalesce(v_settlement.new_contract_value,0)-coalesce(v_settlement.contract_value,0))>0.005
    or coalesce(v_settlement.difference_due,0)>0.005;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'policy_action_id',v_action.id,
    'hold_expires_at',v_hold.expires_at,
    'new_start_at',v_hold.requested_start_at,
    'new_end_at',v_hold.requested_end_at,
    'contract_value',v_settlement.contract_value,
    'new_contract_value',v_settlement.new_contract_value,
    'penalty_amount',v_settlement.penalty_retained,
    'confirmation_target_amount',v_settlement.confirmation_target_amount,
    'current_contract_coverage',v_current_coverage,
    'coverage_after_penalty',v_coverage_after_penalty,
    'outstanding_difference',v_outstanding,
    'requires_payment',v_outstanding>0.005,
    'requires_email_verification',v_financial
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_create_reschedule_difference_payment_intent_standard(p_policy_action_id uuid, p_method text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_coverage numeric(12,2);
  v_outstanding numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
  v_amounts jsonb;
  v_id uuid;
  v_method text:=upper(btrim(coalesce(p_method,'')));
begin
  if v_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if nullif(btrim(p_idempotency_key),'') is null then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.policy_action_id is distinct from p_policy_action_id or v_existing.method<>v_method then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT'; end if;
    return jsonb_build_object('transaction_id',v_existing.id,'policy_action_id',p_policy_action_id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,'contract_amount_settled',v_existing.contract_amount_settled,'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'provider',v_existing.provider,'idempotent_replay',true);
  end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' or v_action.status not in ('AWAITING_DIFFERENCE_PAYMENT','PREVIEW') then raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_PAYABLE'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  v_coverage:=round(greatest(public.appointment_contract_coverage_amount(v_action.appointment_id)-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  if v_outstanding<=0 then raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_ALREADY_SATISFIED'; end if;
  v_discount_percent:=public.service_resolve_appointment_pix_discount(v_action.appointment_id);
  v_amounts:=public.service_calculate_payment_cash_amount(v_outstanding,v_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash:=(v_amounts->>'cash_amount')::numeric;
  insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,idempotency_key,requested_percentage,payment_purpose,policy_action_id)
  values(v_action.appointment_id,'CHARGE',v_method,'MERCADO_PAGO','PENDING',v_outstanding,v_discount,v_cash,p_idempotency_key,null,'CONTRACT',v_action.id)
  returning id into v_id;
  return jsonb_build_object('transaction_id',v_id,'policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','PENDING','payment_kind','RESCHEDULE_DIFFERENCE','contract_amount_settled',v_outstanding,'payment_discount_amount',v_discount,'cash_amount',v_cash,'method',v_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_create_reschedule_difference_payment_intent(p_policy_action_id uuid, p_method text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_existing public.payment_transactions%rowtype;
  v_method text:=upper(btrim(coalesce(p_method,'')));
begin
  if v_method not in ('PIX','CARD') then
    raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  select *
  into v_existing
  from public.payment_transactions
  where policy_action_id=p_policy_action_id
    and transaction_type='CHARGE'
    and provider='MERCADO_PAGO'
    and method=v_method
    and status='PENDING'
  order by created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'transaction_id',v_existing.id,
      'policy_action_id',p_policy_action_id,
      'appointment_id',v_existing.appointment_id,
      'status',v_existing.status,
      'payment_kind','RESCHEDULE_DIFFERENCE',
      'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,
      'cash_amount',v_existing.cash_amount,
      'method',v_existing.method,
      'provider',v_existing.provider,
      'idempotent_replay',true
    );
  end if;

  return public.service_create_reschedule_difference_payment_intent_standard(
    p_policy_action_id,p_method,p_idempotency_key
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_get_public_payment_context_standard(p_access_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_id uuid; v_appt public.appointments%rowtype; v_context jsonb;
begin
  v_id:=public.resolve_appointment_access_token(p_access_token,'VIEW');
  select * into strict v_appt from public.appointments where id=v_id;
  if v_appt.billing_mode_snapshot is distinct from 'INVOICE' then return public.payment_context_before_invoice(p_access_token); end if;
  return public.invoice_checkout_result(v_id) || jsonb_build_object(
    'appointment_status',v_appt.status,'service_name',v_appt.service_name_snapshot,
    'commercial_value',v_appt.commercial_value,'contract_balance',greatest(v_appt.commercial_value-public.appointment_contract_coverage_amount(v_id),0),
    'minimum_due_contract_amount',0,'minimum_available',false,'full_available',false,
    'policy_allows_minimum',false,'policy_allows_full',false,'pix_discount_percent',0);
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_quote_reschedule_package_hold(p_appointment_id uuid, p_checkout_hold_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare v_appointment public.appointments%rowtype; v_usage public.appointment_package_usage%rowtype; v_package public.hour_packages%rowtype; v_hold public.checkout_holds%rowtype; v_timezone text; v_local_start timestamp without time zone; v_local_end timestamp without time zone; v_special boolean; v_required bigint; v_surcharge bigint; v_charged bigint; v_delta bigint; v_available bigint; begin select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null; if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if; select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null; if not found then return jsonb_build_object('uses_package',false); end if; select * into v_package from public.hour_packages where id=v_usage.hour_package_id; select * into v_hold from public.checkout_holds where id=p_checkout_hold_id and status='ACTIVE' and expires_at>now(); if not found then raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED'; end if; if v_package.customer_id is distinct from v_appointment.primary_customer_id then raise exception using errcode='P0001',message='HOUR_PACKAGE_CUSTOMER_MISMATCH'; end if; if v_package.status<>'ACTIVE' then raise exception using errcode='P0001',message='HOUR_PACKAGE_NOT_ACTIVE'; end if; if v_hold.requested_start_at<v_package.valid_from or v_hold.requested_start_at>=v_package.valid_until then raise exception using errcode='P0001',message='HOUR_PACKAGE_OUTSIDE_VALIDITY'; end if; if not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id) then raise exception using errcode='P0001',message='HOUR_PACKAGE_SERVICE_NOT_ELIGIBLE'; end if; select timezone into v_timezone from public.operation_settings where id=1; v_local_start:=v_hold.requested_start_at at time zone v_timezone; v_local_end:=v_hold.requested_end_at at time zone v_timezone; v_special:=extract(dow from v_local_start)::integer in(0,6) or v_local_start::date<>v_local_end::date or v_local_start::time<v_package.standard_start_local_time or v_local_end::time>v_package.standard_end_local_time; v_required:=v_hold.duration_minutes::bigint*60; v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end; v_charged:=v_required+v_surcharge; v_delta:=v_charged-v_usage.charged_seconds; select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id; if v_delta>0 and coalesce(v_available,0)<v_delta then raise exception using errcode='P0001',message='HOUR_PACKAGE_INSUFFICIENT_BALANCE'; end if; return jsonb_build_object('uses_package',true,'hour_package_id',v_package.id,'old_required_seconds',v_usage.required_seconds,'old_surcharge_seconds',v_usage.surcharge_seconds,'old_charged_seconds',v_usage.charged_seconds,'new_required_seconds',v_required,'new_surcharge_seconds',v_surcharge,'new_charged_seconds',v_charged,'delta_seconds',v_delta,'available_seconds',coalesce(v_available,0),'is_special_period',v_special,'special_surcharge_percent',case when v_special then v_package.special_surcharge_percent else 0 end); end; $function$;

CREATE OR REPLACE FUNCTION public.service_reconcile_reschedule_package(p_appointment_id uuid, p_checkout_hold_id uuid, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare v_usage public.appointment_package_usage%rowtype; v_package public.hour_packages%rowtype; v_quote jsonb; v_delta bigint; v_movement_id uuid; v_required bigint; v_surcharge bigint; v_charged bigint; v_special boolean; v_percent numeric(5,2); begin select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null for update; if not found then return jsonb_build_object('uses_package',false,'adjusted',false); end if; select * into v_package from public.hour_packages where id=v_usage.hour_package_id for update; v_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,p_checkout_hold_id); v_delta:=(v_quote->>'delta_seconds')::bigint; v_required:=(v_quote->>'new_required_seconds')::bigint; v_surcharge:=(v_quote->>'new_surcharge_seconds')::bigint; v_charged:=(v_quote->>'new_charged_seconds')::bigint; v_special:=(v_quote->>'is_special_period')::boolean; v_percent:=(v_quote->>'special_surcharge_percent')::numeric; if v_delta<>0 then insert into public.hour_package_movements(hour_package_id,appointment_id,movement_type,minutes_delta,seconds_delta,reason,created_by_admin_id) values(v_usage.hour_package_id,p_appointment_id,'DURATION_ADJUSTMENT',-(v_delta::numeric/60),-v_delta,'APPOINTMENT_RESCHEDULED_PACKAGE_RECONCILIATION',p_admin_id) returning id into v_movement_id; end if; update public.appointment_package_usage set covered_minutes=(v_required/60)::integer,required_seconds=v_required,surcharge_seconds=v_surcharge,charged_seconds=v_charged,covered_reference_value=round(v_package.reference_minute_value*(v_required::numeric/60),2),is_special_period=v_special,special_surcharge_percent=v_percent,special_surcharge_amount=0 where id=v_usage.id; return v_quote||jsonb_build_object('adjusted',v_delta<>0,'adjustment_movement_id',v_movement_id); end; $function$;

revoke all on function public.appointment_contract_coverage_amount(uuid) from public, anon, authenticated;
grant execute on function public.appointment_contract_coverage_amount(uuid) to service_role;
revoke all on function public.create_checkout_hold_for_reschedule(uuid,timestamp with time zone) from public, anon, authenticated;
grant execute on function public.create_checkout_hold_for_reschedule(uuid,timestamp with time zone) to service_role;
grant execute on function public.create_checkout_hold_for_reschedule(uuid,timestamp with time zone) to public;
revoke all on function public.enforce_appointment_reschedule_limit(uuid,text) from public, anon, authenticated;
grant execute on function public.enforce_appointment_reschedule_limit(uuid,text) to service_role;
revoke all on function public.service_admin_apply_reschedule(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_apply_reschedule(uuid,uuid) to service_role;
revoke all on function public.service_admin_create_reschedule_hold_standard(uuid,timestamp with time zone,timestamp with time zone,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold_standard(uuid,timestamp with time zone,timestamp with time zone,text,uuid) to service_role;
revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamp with time zone,timestamp with time zone,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamp with time zone,timestamp with time zone,text,uuid) to service_role;
revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamp with time zone,timestamp with time zone,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamp with time zone,timestamp with time zone,uuid) to service_role;
revoke all on function public.service_admin_list_reschedule_slots(uuid,date) from public, anon, authenticated;
grant execute on function public.service_admin_list_reschedule_slots(uuid,date) to service_role;
revoke all on function public.service_client_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) from public, anon, authenticated;
grant execute on function public.service_client_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) to service_role;
revoke all on function public.service_client_reschedule_requirements(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_client_reschedule_requirements(uuid,uuid) to service_role;
revoke all on function public.service_create_reschedule_difference_payment_intent_standard(uuid,text,text) from public, anon, authenticated;
grant execute on function public.service_create_reschedule_difference_payment_intent_standard(uuid,text,text) to service_role;
revoke all on function public.service_create_reschedule_difference_payment_intent(uuid,text,text) from public, anon, authenticated;
grant execute on function public.service_create_reschedule_difference_payment_intent(uuid,text,text) to service_role;
revoke all on function public.service_get_public_payment_context_standard(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_context_standard(text) to service_role;
revoke all on function public.service_quote_reschedule_package_hold(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_quote_reschedule_package_hold(uuid,uuid) to service_role;
revoke all on function public.service_reconcile_reschedule_package(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_reconcile_reschedule_package(uuid,uuid,uuid) to service_role;

-- ===== Ampliação de duração =====

-- Ampliar no mesmo horário não consome a remarcação da cliente.
CREATE OR REPLACE FUNCTION public.appointment_client_reschedule_count(p_appointment_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$ select count(*)::integer from public.appointment_policy_actions apa where apa.appointment_id=p_appointment_id and apa.action_type='RESCHEDULE' and apa.change_origin='CLIENT' and apa.status='APPLIED' and not apa.is_duration_extension_only; $function$;

CREATE OR REPLACE FUNCTION public.create_checkout_hold_for_reschedule(p_appointment_id uuid, p_requested_start_at timestamp with time zone, p_duration_blocks integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_discount public.appointment_discounts%rowtype;
  v_has_discount boolean := false;
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[]:='{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
  v_contracted_minutes integer;
  v_range record;
  v_own_ranges tstzmultirange;
  v_delta_ranges tstzmultirange;
  v_segment tstzrange;
  v_pre_discount_value numeric(12,2) := 0;
  v_discount_amount numeric(12,2) := 0;
  v_commercial_value numeric(12,2) := 0;
  v_pricing_version text;
  v_blocks integer;
  v_max_blocks integer;
begin
  perform public.expire_due_checkout_holds();

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id and deleted_at is null;

  if not found or v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  -- Duração nova: só igual ou maior que a contratada, dentro do máximo do serviço.
  v_blocks:=coalesce(p_duration_blocks,v_appointment.duration_blocks);
  if p_duration_blocks is not null and p_duration_blocks is distinct from v_appointment.duration_blocks then
    if v_appointment.duration_blocks is null then
      raise exception using errcode='P0001',message='RESCHEDULE_DURATION_FIXED_SERVICE';
    end if;
    if p_duration_blocks<v_appointment.duration_blocks then
      raise exception using errcode='P0001',message='RESCHEDULE_DURATION_DECREASE_NOT_ALLOWED';
    end if;
    select maximum_booking_blocks into v_max_blocks from public.services where id=v_appointment.service_id;
    if v_max_blocks is not null and p_duration_blocks>v_max_blocks then
      raise exception using errcode='P0001',message='RESCHEDULE_DURATION_INVALID';
    end if;
  end if;

  select *
    into v_discount
  from public.appointment_discounts
  where appointment_id=p_appointment_id;
  v_has_discount := found;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity)
      order by ae.extra_id
    ),
    '[]'::jsonb
  )
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  v_contracted_minutes:=public.resolve_service_contracted_minutes(
    v_appointment.service_id,
    v_blocks
  );

  select timezone into v_timezone
  from public.operation_settings
  where id=1;

  v_requested_local_date:=(p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date,
      null,
      p_appointment_id
    )
    union all
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date+1,
      null,
      p_appointment_id
    )
  ) s
  where s.slot_start_at=p_requested_start_at
    -- O mesmo início só vale quando a duração aumenta (ampliação).
    and (s.core_start_at is distinct from v_appointment.core_start_at or v_blocks is distinct from v_appointment.duration_blocks)
    and not exists(
      select 1
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        s.core_start_at,
        v_blocks
      ) rr
      where not public.google_resource_sync_is_ready(rr.resource_id,600)
    )
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end if;

  -- A remarcação parte do preço atual do novo horário, mas preserva a
  -- condição comercial já contratada. O desconto é um snapshot da reserva,
  -- não uma nova aplicação/consumo de cupom.
  v_quote:=public.calculate_booking_quote_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_blocks,
    v_extras,
    v_appointment.people_count,
    v_slot.core_start_at,
    null
  );

  v_pre_discount_value:=round(
    greatest(coalesce((v_quote->>'commercial_value')::numeric,0),0),
    2
  );
  v_commercial_value:=v_pre_discount_value;
  v_pricing_version:=coalesce(v_quote->>'pricing_version','');

  if v_has_discount then
    if v_discount.discount_type_snapshot='PERCENT' then
      v_discount_amount:=round(
        public.coupon_discount_amount('PERCENT',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>'extras_total')::numeric,0)),
        2
      );
    elsif v_discount.discount_type_snapshot='FIXED' then
      v_discount_amount:=round(
        public.coupon_discount_amount('FIXED',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>'extras_total')::numeric,0)),
        2
      );
    else
      raise exception using errcode='P0001',message='APPOINTMENT_DISCOUNT_SNAPSHOT_INVALID';
    end if;

    v_discount_amount:=round(
      least(greatest(v_discount_amount,0),v_pre_discount_value),
      2
    );
    v_commercial_value:=round(
      greatest(v_pre_discount_value-v_discount_amount,0),
      2
    );

    v_pricing_version:=md5(concat_ws(
      '|',
      v_pricing_version,
      'RESCHEDULE_DISCOUNT_SNAPSHOT_V1',
      coalesce(v_discount.code_snapshot,''),
      v_discount.discount_type_snapshot,
      v_discount.discount_value_snapshot::text
    ));

    v_quote:=v_quote || jsonb_build_object(
      'coupon_code',v_discount.code_snapshot,
      'coupon_discount',v_discount_amount,
      'discount_amount',v_discount_amount,
      'pre_discount_value',v_pre_discount_value,
      'commercial_value',v_commercial_value,
      'total_amount',v_commercial_value,
      'discount_source','APPOINTMENT_SNAPSHOT',
      'discount_snapshot_type',v_discount.discount_type_snapshot,
      'discount_snapshot_value',v_discount.discount_value_snapshot,
      'pricing_version',v_pricing_version
    );
  end if;

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_appointment.service_id,
    v_extras,
    v_slot.core_start_at,
    v_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001',message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(s.checkout_hold_minutes,os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s
  cross join public.operation_settings os
  where s.id=v_appointment.service_id and os.id=1;

  v_expires_at:=coalesce(
    nullif(current_setting('agenda.test_now',true),'')::timestamptz,
    now()
  )+make_interval(mins=>v_hold_minutes);

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_token_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  v_selection_hash:=md5(concat_ws(
    '|',
    'RESCHEDULE',
    p_appointment_id::text,
    v_appointment.service_id::text,
    v_appointment.service_employee_id::text,
    coalesce(v_blocks::text,'FIXED'),
    v_extras::text,
    v_appointment.people_count::text,
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
    v_pricing_version
  ));

  insert into public.checkout_holds(
    public_token_hash,
    service_id,
    service_employee_id,
    selection_hash,
    people_count,
    requested_start_at,
    requested_end_at,
    core_start_at,
    core_end_at,
    pre_service_minutes,
    post_service_minutes,
    schedule_profile,
    status,
    expires_at,
    extra_selections,
    commercial_value,
    pricing_version,
    duration_minutes,
    resource_ids,
    duration_blocks,
    contracted_minutes,
    primary_customer_id,
    quote_snapshot,
    applied_coupon_id,
    coupon_code_snapshot,
    coupon_discount,
    pre_discount_value
  ) values(
    v_token_hash,
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_selection_hash,
    v_appointment.people_count,
    v_slot.slot_start_at,
    v_slot.slot_end_at,
    v_slot.core_start_at,
    v_slot.core_end_at,
    v_slot.pre_service_minutes,
    v_slot.post_service_minutes,
    v_quote->'schedule_profile',
    'ACTIVE',
    v_expires_at,
    v_extras,
    v_commercial_value,
    v_pricing_version,
    v_slot.duration_minutes,
    v_resource_ids,
    v_blocks,
    v_contracted_minutes,
    v_appointment.primary_customer_id,
    v_quote,
    case when v_has_discount then v_discount.coupon_id else null end,
    case when v_has_discount then v_discount.code_snapshot else null end,
    case when v_has_discount then v_discount_amount else 0 end,
    case when v_has_discount then v_pre_discount_value else null end
  )
  returning id into v_hold_id;

  -- A reserva atual já protege a parte sobreposta. O hold de remarcação segura
  -- apenas os trechos NOVOS fora da ocupação atual, evitando conflito consigo mesma.
  begin
    for v_range in
      select *
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        v_slot.core_start_at,
        v_blocks
      )
    loop
      select coalesce(range_agg(ra.occupied_range),'{}'::tstzmultirange)
      into v_own_ranges
      from public.resource_allocations ra
      where ra.appointment_id=p_appointment_id
        and ra.resource_id=v_range.resource_id
        and ra.allocation_type='APPOINTMENT'
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');

      v_delta_ranges:=tstzmultirange(v_range.occupied_range)-v_own_ranges;

      for v_segment in select unnest(v_delta_ranges)
      loop
        insert into public.resource_allocations(
          resource_id,
          checkout_hold_id,
          allocation_type,
          status,
          occupied_range
        )
        values(
          v_range.resource_id,
          v_hold_id,
          'CHECKOUT_HOLD',
          'HELD',
          v_segment
        );
      end loop;
    end loop;
  exception
    when exclusion_violation then
      update public.checkout_holds
      set status='INVALIDATED',updated_at=now()
      where id=v_hold_id;

      raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token',v_raw_token,
    'checkout_hold_id',v_hold_id,
    'status','ACTIVE',
    'expires_at',v_expires_at,
    'slot_start_at',v_slot.slot_start_at,
    'slot_end_at',v_slot.slot_end_at,
    'core_start_at',v_slot.core_start_at,
    'core_end_at',v_slot.core_end_at,
    'pre_service_minutes',v_slot.pre_service_minutes,
    'post_service_minutes',v_slot.post_service_minutes,
    'commercial_value',v_commercial_value,
    'duration_minutes',v_slot.duration_minutes,
    'duration_blocks',v_blocks,
    'contracted_minutes',v_contracted_minutes,
    'pricing_version',v_pricing_version
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_list_reschedule_slots(p_appointment_id uuid, p_local_date date, p_duration_blocks integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_extras jsonb;
  v_timezone text;
  v_available bigint;
  v_old_charged bigint;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_required bigint;
  v_surcharge bigint;
  v_delta bigint;
  v_special boolean;
  v_result jsonb:='[]'::jsonb;
  r record;
  v_blocks integer;
  v_max_blocks integer;
begin
  if p_local_date is null then raise exception using errcode='P0001',message='RESCHEDULE_DATE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  v_blocks:=coalesce(p_duration_blocks,v_appointment.duration_blocks);
  if p_duration_blocks is not null and p_duration_blocks is distinct from v_appointment.duration_blocks then
    if v_appointment.duration_blocks is null then raise exception using errcode='P0001',message='RESCHEDULE_DURATION_FIXED_SERVICE'; end if;
    if p_duration_blocks<v_appointment.duration_blocks then raise exception using errcode='P0001',message='RESCHEDULE_DURATION_DECREASE_NOT_ALLOWED'; end if;
    select maximum_booking_blocks into v_max_blocks from public.services where id=v_appointment.service_id;
    if v_max_blocks is not null and p_duration_blocks>v_max_blocks then raise exception using errcode='P0001',message='RESCHEDULE_DURATION_INVALID'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null;
  if found then
    select * into v_package from public.hour_packages where id=v_usage.hour_package_id;
    select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id;
    v_old_charged:=v_usage.charged_seconds;
    select timezone into v_timezone from public.operation_settings where id=1;
  end if;

  for r in
    select s.*
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,v_appointment.service_employee_id,v_blocks,
      v_extras,v_appointment.people_count,p_local_date,null,p_appointment_id
    ) s
    where (s.core_start_at is distinct from v_appointment.core_start_at or v_blocks is distinct from v_appointment.duration_blocks)
      and not exists(
        select 1 from public.calculate_booking_resource_ranges_for_duration(
          v_appointment.service_id,v_extras,s.core_start_at,v_blocks
        ) rr where not public.google_resource_sync_is_ready(rr.resource_id,600)
      )
  loop
    if v_usage.id is not null then
      if v_package.status<>'ACTIVE' or r.slot_start_at<v_package.valid_from or r.slot_start_at>=v_package.valid_until
        or not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id)
      then continue; end if;
      v_local_start:=r.slot_start_at at time zone v_timezone;
      v_local_end:=r.slot_end_at at time zone v_timezone;
      v_special:=extract(dow from v_local_start)::integer in(0,6)
        or v_local_start::date<>v_local_end::date
        or v_local_start::time<v_package.standard_start_local_time
        or v_local_end::time>v_package.standard_end_local_time;
      v_required:=r.duration_minutes::bigint*60;
      v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end;
      v_delta:=(v_required+v_surcharge)-v_old_charged;
      if v_delta>0 and coalesce(v_available,0)<v_delta then continue; end if;
    end if;

    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'slot_start_at',r.slot_start_at,'slot_end_at',r.slot_end_at,
      'core_start_at',r.core_start_at,'core_end_at',r.core_end_at,
      'pre_service_minutes',r.pre_service_minutes,'post_service_minutes',r.post_service_minutes,
      'duration_minutes',r.duration_minutes,
      'package_delta_seconds',case when v_usage.id is null then 0 else v_delta end
    ));
  end loop;
  return v_result;
end;
$function$;

-- Remarcação com duração (ampliação). Mesma base da versão de 5 argumentos, mais:
--   * a duração nova só pode ser igual ou maior que a contratada;
--   * ampliar mantendo o mesmo início não conta como remarcação nem tem multa;
--   * ao ampliar, a cliente paga agora pelo menos 50% do acréscimo (ou tudo); o resto
--     vira saldo. O acréscimo é o valor da reserva inteira na nova duração (faixa de
--     preço por bloco da duração total) menos o valor atual.
CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold(p_appointment_id uuid, p_requested_start_at timestamp with time zone, p_requested_at timestamp with time zone, p_change_origin text, p_admin_id uuid, p_duration_blocks integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb;
  v_hold jsonb;
  v_package_quote jsonb;
  v_hold_row public.checkout_holds%rowtype;
  v_hold_id uuid;
  v_action_id uuid;
  v_action_status text;
  v_previous record;
  v_settlement_id uuid;
  v_new_contract_value numeric(12,2);
  v_package_cash_due numeric(12,2);
  v_old_blocks integer;
  v_blocks integer;
  v_extension boolean;
  v_extension_only boolean;
  v_coverage_after numeric(12,2);
  v_increment numeric(12,2);
  v_full_target numeric(12,2);
  v_min_target numeric(12,2);
  v_payment_hold_minutes integer;
  v_new_expires_at timestamptz;
begin
  if p_requested_start_at is null or p_requested_at is null then raise exception using errcode='P0001',message='RESCHEDULE_TIME_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  v_old_blocks:=v_appointment.duration_blocks;
  v_blocks:=coalesce(p_duration_blocks,v_old_blocks);
  v_extension:=v_old_blocks is not null and v_blocks>v_old_blocks;
  v_extension_only:=v_extension and p_requested_start_at=v_appointment.start_at;

  -- Ampliar sem mudar o início não consome remarcação da cliente.
  if not v_extension_only then
    perform public.enforce_appointment_reschedule_limit(p_appointment_id,p_change_origin);
  end if;

  for v_previous in
    select id,reschedule_checkout_hold_id from public.appointment_policy_actions
    where appointment_id=p_appointment_id and action_type='RESCHEDULE' and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') for update
  loop
    if v_previous.reschedule_checkout_hold_id is not null then
      update public.resource_allocations set status='RELEASED',updated_at=now()
      where checkout_hold_id=v_previous.reschedule_checkout_hold_id and allocation_type='CHECKOUT_HOLD' and status='HELD';
      update public.checkout_holds set status='INVALIDATED',updated_at=now()
      where id=v_previous.reschedule_checkout_hold_id and status='ACTIVE';
    end if;
    update public.appointment_policy_actions set status='VOIDED',updated_at=now() where id=v_previous.id;
  end loop;

  v_hold:=public.create_checkout_hold_for_reschedule(p_appointment_id,p_requested_start_at,v_blocks);
  v_hold_id:=(v_hold->>'checkout_hold_id')::uuid;
  select * into v_hold_row from public.checkout_holds where id=v_hold_id;

  v_package_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,v_hold_id);
  if coalesce((v_package_quote->>'uses_package')::boolean,false) then
    select apu.cash_due into v_package_cash_due from public.appointment_package_usage apu
    where apu.appointment_id=p_appointment_id and apu.reversal_movement_id is null;
    if v_package_cash_due is null then raise exception using errcode='P0001',message='RESCHEDULE_PACKAGE_USAGE_MISSING'; end if;
    v_new_contract_value:=round(v_package_cash_due,2);
  else
    v_new_contract_value:=round(v_hold_row.commercial_value,2);
  end if;

  v_preview:=public.calculate_reservation_change(p_appointment_id,'RESCHEDULE',p_requested_at,p_change_origin,v_new_contract_value);
  if not v_extension_only and coalesce((v_preview->>'customer_reschedule_limit_reached')::boolean,false) then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED';
  end if;

  if v_extension_only then
    -- Só mais tempo no mesmo horário: sem multa de remarcação.
    v_preview:=v_preview||jsonb_build_object(
      'penalty_type','NONE','penalty_value',0,'penalty_percent',0,'theoretical_penalty',0,
      'penalty_retained',0,'penalty_amount',0,
      'customer_funds_after_penalty',(v_preview->>'customer_funds_before')::numeric,
      'contract_coverage_after_penalty',(v_preview->>'contract_coverage_before')::numeric,
      'applicable_amount',round(least((v_preview->>'customer_funds_before')::numeric,v_new_contract_value),2),
      'excess_amount',round(greatest((v_preview->>'customer_funds_before')::numeric-v_new_contract_value,0),2)
    );
  end if;

  if v_extension then
    v_coverage_after:=round(coalesce((v_preview->>'contract_coverage_after_penalty')::numeric,0),2);
    v_increment:=round(greatest(v_new_contract_value-coalesce((v_preview->>'contract_value')::numeric,0),0),2);
    v_full_target:=round(least(v_new_contract_value,v_coverage_after+v_increment),2);
    v_min_target:=round(least(v_full_target,v_coverage_after+round(v_increment*0.5,2)),2);
    v_preview:=v_preview||jsonb_build_object(
      'confirmation_target_amount',v_min_target,
      'difference_due',round(greatest(v_min_target-v_coverage_after,0),2)
    );
  end if;

  v_action_status:=case when coalesce((v_preview->>'difference_due')::numeric,0)>0 then 'AWAITING_DIFFERENCE_PAYMENT' else 'PREVIEW' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,hours_before_start,notice_hours_snapshot,
    is_inside_notice_window,prior_customer_reschedules,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,
    refundable_amount,reschedule_checkout_hold_id,created_by_admin_id,change_origin,policy_schema_version,contract_applied_before,excess_before,
    applicable_amount,excess_amount,difference_due,refund_due,
    requested_duration_blocks,extension_increment,extension_full_target,is_duration_extension_only
  ) values(
    p_appointment_id,'RESCHEDULE',v_action_status,p_requested_at,v_appointment.start_at,v_hold_row.requested_start_at,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'customer_funds_before')::numeric,
    'PERCENT'::public.change_penalty_type,
    (v_preview->>'penalty_percent')::numeric,(v_preview->>'penalty_retained')::numeric,0,v_hold_id,p_admin_id,
    p_change_origin,v_preview->>'snapshot_schema_version',(v_preview->>'contract_applied_before')::numeric,(v_preview->>'excess_before')::numeric,
    (v_preview->>'applicable_amount')::numeric,(v_preview->>'excess_amount')::numeric,(v_preview->>'difference_due')::numeric,0,
    v_blocks,case when v_extension then v_increment else null end,case when v_extension then v_full_target else null end,v_extension_only
  ) returning id into v_action_id;

  v_settlement_id:=public.record_appointment_change_settlement(v_action_id,v_preview);

  if v_action_status='AWAITING_DIFFERENCE_PAYMENT' then
    select coalesce(s.payment_hold_minutes,os.payment_hold_minutes,30) into v_payment_hold_minutes
    from public.services s cross join public.operation_settings os
    where s.id=v_appointment.service_id and os.id=1;
    v_new_expires_at:=clock_timestamp()+make_interval(mins=>greatest(coalesce(v_payment_hold_minutes,30),30));
    update public.checkout_holds set expires_at=v_new_expires_at,updated_at=now() where id=v_hold_id and status='ACTIVE';
    select * into v_hold_row from public.checkout_holds where id=v_hold_id;
  end if;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'RESCHEDULE_PREVIEW_CREATED',jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'change_origin',p_change_origin,
    'penalty_retained',v_preview->'penalty_retained','applicable_amount',v_preview->'applicable_amount',
    'new_contract_value',v_new_contract_value,'difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'package_reconciliation',v_package_quote,'old_duration_blocks',v_old_blocks,'duration_blocks',v_blocks,
    'extension_increment',case when v_extension then v_increment else null end,'extension_only',v_extension_only
  ),case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_action_status,'appointment_id',p_appointment_id,
    'change_origin',p_change_origin,'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold_row.expires_at,'slot_start_at',v_hold_row.requested_start_at,
      'slot_end_at',v_hold_row.requested_end_at,'core_start_at',v_hold_row.core_start_at,'core_end_at',v_hold_row.core_end_at),
    'contract_value',v_preview->'contract_value','new_contract_value',v_new_contract_value,'payment_commitment_percent',v_preview->'payment_commitment_percent',
    'confirmation_target_amount',v_preview->'confirmation_target_amount','penalty_percent',v_preview->'penalty_percent','penalty_retained',v_preview->'penalty_retained',
    'applicable_amount',v_preview->'applicable_amount','difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'prior_customer_reschedules',v_preview->'prior_customer_reschedules','max_customer_reschedules',v_preview->'max_customer_reschedules',
    'package_reconciliation',v_package_quote,
    'old_duration_blocks',v_old_blocks,'duration_blocks',v_blocks,'duration_minutes',v_hold_row.contracted_minutes,
    'extension',v_extension,'extension_only',v_extension_only,
    'extension_increment',case when v_extension then v_increment else 0 end,
    'extension_minimum_payment',case when v_extension then round(greatest(v_min_target-v_coverage_after,0),2) else 0 end,
    'extension_full_payment',case when v_extension then round(greatest(v_full_target-v_coverage_after,0),2) else 0 end
  );
end;
$function$;

-- Cobrança da diferença de uma remarcação com a escolha da cliente:
--   MINIMUM = o que falta para a meta de confirmação (na ampliação, 50% do acréscimo);
--   FULL    = na ampliação, o acréscimo inteiro; nas demais remarcações, igual ao MINIMUM.
CREATE OR REPLACE FUNCTION public.service_create_reschedule_difference_payment_intent(p_policy_action_id uuid, p_payment_kind text, p_method text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_coverage numeric(12,2);
  v_minimum numeric(12,2);
  v_full numeric(12,2);
  v_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
  v_amounts jsonb;
  v_id uuid;
  v_kind text:=upper(btrim(coalesce(p_payment_kind,'')));
  v_method text:=upper(btrim(coalesce(p_method,'')));
begin
  if v_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if v_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if nullif(btrim(p_idempotency_key),'') is null then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.policy_action_id is distinct from p_policy_action_id or v_existing.method<>v_method
       or coalesce(v_existing.requested_payment_kind,v_kind)<>v_kind then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object('transaction_id',v_existing.id,'policy_action_id',p_policy_action_id,'appointment_id',v_existing.appointment_id,
      'status',v_existing.status,'payment_kind','RESCHEDULE_DIFFERENCE','requested_payment_kind',v_kind,
      'contract_amount_settled',v_existing.contract_amount_settled,'payment_discount_amount',v_existing.payment_discount_amount,
      'cash_amount',v_existing.cash_amount,'method',v_existing.method,'provider',v_existing.provider,'idempotent_replay',true);
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' or v_action.status not in ('AWAITING_DIFFERENCE_PAYMENT','PREVIEW') then
    raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_PAYABLE';
  end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  v_coverage:=round(greatest(public.appointment_contract_coverage_amount(v_action.appointment_id)-v_settlement.penalty_retained,0),2);
  v_minimum:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  v_full:=case when v_action.extension_full_target is not null
    then round(greatest(v_action.extension_full_target-v_coverage,v_minimum),2)
    else v_minimum end;
  v_amount:=case when v_kind='FULL' then v_full else v_minimum end;
  if v_amount<=0 then raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_ALREADY_SATISFIED'; end if;

  v_discount_percent:=public.service_resolve_appointment_pix_discount(v_action.appointment_id);
  v_amounts:=public.service_calculate_payment_cash_amount(v_amount,v_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,
    cash_amount,idempotency_key,requested_percentage,requested_payment_kind,payment_purpose,policy_action_id)
  values(v_action.appointment_id,'CHARGE',v_method,'MERCADO_PAGO','PENDING',v_amount,v_discount,v_cash,p_idempotency_key,null,v_kind,'CONTRACT',v_action.id)
  returning id into v_id;

  return jsonb_build_object('transaction_id',v_id,'policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','PENDING',
    'payment_kind','RESCHEDULE_DIFFERENCE','requested_payment_kind',v_kind,'contract_amount_settled',v_amount,
    'payment_discount_amount',v_discount,'cash_amount',v_cash,'method',v_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$function$;

-- Depois que o Mercado Pago aprova a diferença de uma remarcação feita pela cliente, a
-- remarcação é aplicada na hora: a cliente nunca fica paga e não remarcada. Sem
-- remarcação pendente (ou já aplicada), não faz nada. Uma falha (por exemplo, o
-- horário segurado expirou) fica na auditoria e o valor pago continua na reserva.
CREATE OR REPLACE FUNCTION public.service_apply_paid_client_reschedule(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tx public.payment_transactions%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_result jsonb;
begin
  select * into v_tx from public.payment_transactions where id=p_transaction_id;
  if not found or v_tx.policy_action_id is null or v_tx.status<>'APPROVED' then
    return jsonb_build_object('applied',false,'reason','NOT_A_PAID_RESCHEDULE');
  end if;
  select * into v_action from public.appointment_policy_actions where id=v_tx.policy_action_id;
  if not found or v_action.action_type<>'RESCHEDULE' or v_action.change_origin<>'CLIENT' then
    return jsonb_build_object('applied',false,'reason','NOT_A_CLIENT_RESCHEDULE');
  end if;
  if v_action.status='APPLIED' then
    return jsonb_build_object('applied',false,'reason','ALREADY_APPLIED','policy_action_id',v_action.id);
  end if;
  if v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then
    return jsonb_build_object('applied',false,'reason','RESCHEDULE_NOT_PENDING','policy_action_id',v_action.id);
  end if;
  begin
    v_result:=public.service_admin_apply_reschedule(v_action.id,null);
  exception when others then
    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values('APPOINTMENT',v_action.appointment_id,'RESCHEDULE_AUTO_APPLY_FAILED',
      jsonb_build_object('policy_action_id',v_action.id,'transaction_id',v_tx.id,'error',left(sqlerrm,200)),'SYSTEM');
    return jsonb_build_object('applied',false,'reason','APPLY_FAILED','error',left(sqlerrm,200),'policy_action_id',v_action.id);
  end;
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values('APPOINTMENT',v_action.appointment_id,'RESCHEDULE_APPLIED_AFTER_PAYMENT',
    jsonb_build_object('policy_action_id',v_action.id,'transaction_id',v_tx.id,'amount',v_tx.contract_amount_settled,
      'requested_payment_kind',v_tx.requested_payment_kind),'SYSTEM');
  return v_result||jsonb_build_object('applied',true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_get_public_payment_context(p_access_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_hash text;
  v_token public.appointment_access_tokens%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_requirements jsonb;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_outstanding numeric(12,2);
  v_full numeric(12,2);
  v_extension boolean;
  v_card_max integer;
  v_pix_discount numeric(5,2);
begin
  if p_access_token is null or length(btrim(p_access_token)) < 32 then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  v_hash := encode(digest(btrim(p_access_token),'sha256'),'hex');

  select *
  into v_token
  from public.appointment_access_tokens
  where token_hash=v_hash
    and scope='RESCHEDULE'
    and revoked_at is null
    and consumed_at is null
    and expires_at is not null
    and expires_at>clock_timestamp()
  order by created_at desc
  limit 1;

  if not found then
    return public.service_get_public_payment_context_standard(p_access_token);
  end if;

  select *
  into v_action
  from public.appointment_policy_actions
  where appointment_id=v_token.appointment_id
    and action_type='RESCHEDULE'
    and change_origin='CLIENT'
    and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT')
  order by created_at desc
  limit 1;

  if not found then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;

  v_requirements := public.service_client_reschedule_requirements(v_token.id,v_action.id);
  v_outstanding := round(greatest(coalesce((v_requirements->>'outstanding_difference')::numeric,0),0),2);
  -- Ampliação de duração: a cliente escolhe pagar 50% do acréscimo (mínimo) ou o
  -- acréscimo inteiro; o que não pagar agora fica como saldo da reserva.
  v_extension := v_action.extension_full_target is not null;
  v_full := case when v_extension
    then round(greatest(v_action.extension_full_target-coalesce((v_requirements->>'coverage_after_penalty')::numeric,0),v_outstanding),2)
    else v_outstanding end;

  select *
  into v_appointment
  from public.appointments
  where id=v_token.appointment_id and deleted_at is null;

  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select *
  into v_customer
  from public.customers
  where id=v_appointment.primary_customer_id;

  if not found then
    raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND';
  end if;

  v_card_max := coalesce(
    v_appointment.card_max_installments_snapshot,
    (select s.card_max_installments from public.services s where s.id=v_appointment.service_id),
    1
  );
  v_pix_discount := public.service_resolve_appointment_pix_discount(v_appointment.id);

  return jsonb_build_object(
    'billing_mode','CHECKOUT',
    'payment_required',v_outstanding>0.005,
    'requires_manual_confirmation',false,
    'appointment_id',v_appointment.id,
    'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,
    'financial_status',v_appointment.financial_status,
    'service_name',coalesce(v_appointment.service_name_snapshot,'Locação do estúdio'),
    'commercial_description',case when v_extension then 'Acréscimo de tempo na reserva' else 'Diferença de remarcação' end,
    'provider_commercial_description',case when v_extension then 'BlackSheep - acréscimo de tempo' else 'BlackSheep - diferença de remarcação' end,
    'contracted_minutes',v_appointment.contracted_minutes,
    'hold_expires_at',v_requirements->>'hold_expires_at',
    'commercial_value',coalesce((v_requirements->>'new_contract_value')::numeric,v_appointment.commercial_value),
    'contract_settled',round(public.appointment_contract_coverage_amount(v_appointment.id),2),
    'contract_balance',v_full,
    'confirmation_percentage',case when v_extension and v_full>v_outstanding+0.005 then 50 else 100 end,
    'minimum_payment_type','FIXED',
    'minimum_payment_value',v_outstanding,
    'confirmation_target_amount',coalesce((v_requirements->>'confirmation_target_amount')::numeric,0),
    'minimum_due_contract_amount',v_outstanding,
    'minimum_available',v_extension and v_full>v_outstanding+0.005 and v_outstanding>0.005,
    'full_available',v_full>0.005,
    'payment_mode',case when v_extension and v_full>v_outstanding+0.005 then 'MINIMUM_OR_FULL' else 'FULL_ONLY' end,
    'policy_allows_minimum',v_extension and v_full>v_outstanding+0.005,
    'policy_allows_full',true,
    'pix_discount_percent',v_pix_discount,
    'card_max_installments',v_card_max,
    'payer',jsonb_build_object(
      'name',coalesce(v_customer.name,''),
      'email',coalesce(v_customer.email,''),
      'tax_id',coalesce(v_customer.cpf_cnpj,'')
    ),
    'reschedule',jsonb_build_object(
      'policy_action_id',v_action.id,
      'new_start_at',v_requirements->>'new_start_at',
      'new_end_at',v_requirements->>'new_end_at',
      'hold_expires_at',v_requirements->>'hold_expires_at',
      'outstanding_difference',v_outstanding,
      'extension',v_extension,
      'extension_increment',v_action.extension_increment,
      'extension_minimum_payment',case when v_extension then v_outstanding else null end,
      'extension_full_payment',case when v_extension then v_full else null end,
      'duration_blocks',v_action.requested_duration_blocks
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_create_payment_intent_by_token(p_access_token text, p_payment_kind text, p_method text, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_idempotency_key text;
  v_result jsonb;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_amounts jsonb;
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_payment_mode text;
  v_reschedule_token public.appointment_access_tokens%rowtype;
  v_reschedule_action_id uuid;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  -- Link de gerenciar reserva (token RESCHEDULE): paga a diferença da remarcação ou o
  -- acréscimo de tempo da ampliação, nunca o contrato inteiro.
  select * into v_reschedule_token from public.appointment_access_tokens
  where token_hash=encode(digest(btrim(p_access_token),'sha256'),'hex') and scope='RESCHEDULE'
    and revoked_at is null and consumed_at is null and expires_at is not null and expires_at>clock_timestamp()
  order by created_at desc limit 1;
  if found then
    select id into v_reschedule_action_id from public.appointment_policy_actions
    where appointment_id=v_reschedule_token.appointment_id and action_type='RESCHEDULE' and change_origin='CLIENT'
      and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT')
    order by created_at desc limit 1;
    if v_reschedule_action_id is null then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID'; end if;
    -- Confere que o horário segurado ainda vale antes de cobrar.
    perform public.service_client_reschedule_requirements(v_reschedule_token.id,v_reschedule_action_id);
    return public.service_create_reschedule_difference_payment_intent(
      v_reschedule_action_id,p_payment_kind,p_method,
      'public:'||v_reschedule_token.appointment_id::text||':'||p_request_key
    )||jsonb_build_object('balance_collection_id',null);
  end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if coalesce(v_appointment.payment_provider_snapshot,'MERCADO_PAGO') <> 'MERCADO_PAGO' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;
  if v_appointment.billing_mode_snapshot='INVOICE' then
    raise exception using errcode='P0001',message='INVOICE_CHECKOUT_PAYMENT_NOT_REQUIRED';
  end if;

  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;
  v_payment_mode:=coalesce(
    v_appointment.payment_mode_snapshot,
    (select s.payment_mode from public.services s where s.id=v_appointment.service_id),
    'MINIMUM_OR_FULL'
  );

  if v_collection_id is not null then
    if v_payment_mode='MINIMUM_ONLY' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_POLICY_DENIED:Esta reserva permite online apenas o sinal. Quite o saldo presencialmente e registre a baixa manual na Gestão.';
    end if;

    perform public.expire_due_balance_collections();
    select * into v_collection from public.appointment_balance_collections where id=v_collection_id for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH'; end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE'; end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;

    if v_collection.provider_refresh_pending then
      raise exception using errcode='P0001',message='BALANCE_PROVIDER_REFRESH_PENDING';
    end if;
    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    select * into v_existing from public.payment_transactions where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id or v_existing.method<>p_method
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      if abs(v_existing.contract_amount_settled-v_balance)>0.005 then
        raise exception using errcode='P0001',message='BALANCE_PAYMENT_AMOUNT_CHANGED';
      end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
        'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true
      );
    end if;

    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;
    v_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment_id);
    v_amounts:=public.service_calculate_payment_cash_amount(v_balance,p_method,v_discount_percent);
    v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
    v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,requested_payment_kind,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_balance,v_discount,v_cash_amount,
      v_idempotency_key,100,'FULL','CONTRACT',v_collection_id
    ) returning id into v_transaction_id;

    return jsonb_build_object(
      'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'payment_mode',v_payment_mode,
      'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,'method',p_method,'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,'idempotent_replay',false
    );
  end if;

  v_result:=public.create_payment_intent_v2(v_appointment_id,p_payment_kind,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$function$;

revoke all on function public.create_checkout_hold_for_reschedule(uuid,timestamptz,integer) from public, anon, authenticated;
revoke all on function public.service_admin_list_reschedule_slots(uuid,date,integer) from public, anon, authenticated;
revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,text,uuid,integer) from public, anon, authenticated;
revoke all on function public.service_create_reschedule_difference_payment_intent(uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.service_apply_paid_client_reschedule(uuid) from public, anon, authenticated;
grant execute on function public.create_checkout_hold_for_reschedule(uuid,timestamptz,integer) to service_role;
grant execute on function public.service_admin_list_reschedule_slots(uuid,date,integer) to service_role;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,text,uuid,integer) to service_role;
grant execute on function public.service_create_reschedule_difference_payment_intent(uuid,text,text,text) to service_role;
grant execute on function public.service_apply_paid_client_reschedule(uuid) to service_role;
