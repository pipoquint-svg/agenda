-- Adding a post-booking extra (e.g. 30 extra minutes) to a reservation that was already paid
-- sent only the balance e-mail: the WhatsApp balance message is scheduled before the end and
-- was skipped then (nothing to pay), and a schedule that already passed is never re-created.
-- An extra added after that time now also queues the approved WhatsApp balance message right
-- away (decision of 2026-10-23). Body otherwise identical to production.

create or replace function public.service_admin_add_post_booking_extra(p_appointment_id uuid, p_kind text, p_extra_id uuid, p_quantity integer, p_admin_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_a public.appointments%rowtype; v_e public.extras%rowtype; v_q jsonb;
  v_unit numeric(14,6); v_total numeric(12,2); v_name text; v_unit_name text;
  v_before numeric(12,2); v_after numeric(12,2); v_row public.appointment_post_booking_extras%rowtype;
  v_collection public.appointment_balance_collections%rowtype; v_existing jsonb;
  v_sequence integer; v_notice text; v_has_provider boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_request_id is null or p_quantity is null or p_quantity<1 then
    raise exception 'APPOINTMENT_EXTRA_REQUEST_INVALID';
  end if;
  select * into v_a from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  select jsonb_build_object('id',x.id,'kind',x.kind,'quantity',x.quantity,
    'unit_price',x.unit_price_snapshot,'total',x.total,'balance_after',
    (public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric)
    into v_existing from public.appointment_post_booking_extras x
    where x.appointment_id=p_appointment_id and x.idempotency_key=p_request_id;
  if v_existing is not null then
    select * into v_collection from public.appointment_balance_collections
      where appointment_id=p_appointment_id order by sequence desc limit 1;
    return v_existing||jsonb_build_object('idempotent_replay',true,
      'collection_id',v_collection.id,
      'notification',case when v_collection.provider_refresh_pending then 'PROVIDER_REFRESH_PENDING'
        else 'LINK_UPDATED' end);
  end if;
  if (select operation_scope from public.services where id=v_a.service_id)<>'BLACKSHEEP'
     or v_a.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then
    raise exception 'APPOINTMENT_EXTRA_NOT_ALLOWED';
  end if;
  if coalesce(v_a.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
    raise exception 'APPOINTMENT_EXTRA_INVOICE_POLICY_UNSUPPORTED';
  end if;
  if p_kind='EXTRA_TIME' then
    if p_extra_id is not null then raise exception 'APPOINTMENT_EXTRA_KIND_INVALID'; end if;
    v_q:=public.appointment_original_time_quote(p_appointment_id);
    v_unit:=(v_q->>'unit_price')::numeric; v_total:=round((v_q->>'price')::numeric*p_quantity/(v_q->>'blocks')::numeric,2);
    v_name:='Tempo extra'; v_unit_name:='30_MIN_BLOCK';
  else
    select e.* into v_e from public.extras e join public.service_extras se on se.extra_id=e.id
    where e.id=p_extra_id and se.service_id=v_a.service_id and e.is_active and e.post_booking_kind=p_kind
    for share of e;
    if not found then raise exception 'APPOINTMENT_EXTRA_NOT_AVAILABLE'; end if;
    v_unit:=v_e.price; v_total:=round(v_unit*p_quantity,2);
    v_name:=v_e.name;
    v_unit_name:=case when p_kind in ('ASSISTANCE','SOCIAL_COVERAGE') then 'HOUR' else 'ITEM' end;
  end if;
  if v_total<=0 then raise exception 'APPOINTMENT_EXTRA_PRICE_INVALID'; end if;
  v_before:=coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0);
  insert into public.appointment_post_booking_extras(
    appointment_id,kind,extra_id,name_snapshot,quantity,unit,unit_price_snapshot,total,
    original_price_snapshot,original_blocks_snapshot,admin_id,idempotency_key
  ) values(p_appointment_id,p_kind,p_extra_id,v_name,p_quantity,v_unit_name,v_unit,v_total,
    case when p_kind='EXTRA_TIME' then (v_q->>'price')::numeric else null end,
    case when p_kind='EXTRA_TIME' then (v_q->>'blocks')::integer else null end,
    p_admin_id,p_request_id) returning * into v_row;
  v_after:=coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0);
  perform public.refresh_appointment_financial_status(p_appointment_id);
  perform public.expire_due_balance_collections();
  select * into v_collection from public.appointment_balance_collections
  where appointment_id=p_appointment_id order by sequence desc limit 1 for update;
  if found and v_collection.status='PENDING' and v_collection.expires_at>public.balance_collection_clock() then
    select exists(select 1 from public.payment_transactions pt where pt.balance_collection_id=v_collection.id
      and pt.status='PENDING' and pt.provider='MERCADO_PAGO') into v_has_provider;
    update public.appointment_balance_collections set provider_refresh_pending=v_has_provider,
      updated_at=now() where id=v_collection.id;
    v_notice:=case when v_has_provider then 'PROVIDER_REFRESH_PENDING' else 'LINK_UPDATED' end;
  else
    select coalesce(max(sequence),0)+1 into v_sequence from public.appointment_balance_collections
    where appointment_id=p_appointment_id;
    insert into public.appointment_balance_collections(
      appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at
    ) values(p_appointment_id,v_sequence,'POST_BOOKING_EXTRA','PENDING',v_after,
      public.balance_collection_clock(),public.balance_collection_clock()+interval '48 hours')
      returning * into v_collection;
    insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
    values('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,
      jsonb_build_object('appointment_id',p_appointment_id,'source','POST_BOOKING_EXTRA'),
      'rental-balance-email:'||v_collection.id::text) on conflict(idempotency_key) do nothing;
    -- WhatsApp: the balance message goes before the end of the reservation. An extra added
    -- after that time (the reservation was paid then, so nothing was sent) is announced right
    -- away, like the e-mail. Before that time, the scheduled message carries the new balance.
    insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
    select 'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',a.id,a.version,
      jsonb_build_object('event_key','RENTAL_BALANCE_DUE','channel','WHATSAPP','template_id',t.id::text,
        'schedule_key',t.id::text||':'||a.version::text||':'||t.schedule_mode||':'||t.schedule_offset_minutes::text,
        'reason','POST_BOOKING_EXTRA'),
      now(),
      'rental-balance-whatsapp:'||v_collection.id::text||':'||t.id::text
    from public.appointments a
    join public.services s on s.id=a.service_id and s.operation_scope='BLACKSHEEP'
    join public.notification_template_configs t on t.event_key='RENTAL_BALANCE_DUE' and t.channel='WHATSAPP'
      and t.audience='CUSTOMER' and t.is_active and t.schedule_mode<>'IMMEDIATE'
      and (t.operation_scope is null or t.operation_scope=s.operation_scope)
    where a.id=p_appointment_id and a.status='CONFIRMED'
      and (not exists(select 1 from public.notification_template_services ts where ts.template_id=t.id)
        or exists(select 1 from public.notification_template_services ts where ts.template_id=t.id and ts.service_id=a.service_id))
      and case t.schedule_mode
        when 'BEFORE_START' then a.start_at-make_interval(mins=>t.schedule_offset_minutes)
        when 'AFTER_START' then a.start_at+make_interval(mins=>t.schedule_offset_minutes)
        when 'BEFORE_END' then a.core_end_at-make_interval(mins=>t.schedule_offset_minutes)
        else a.core_end_at+make_interval(mins=>t.schedule_offset_minutes)
      end<=public.balance_collection_clock()
    on conflict(idempotency_key) do nothing;
    v_notice:='EMAIL_QUEUED';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',p_appointment_id,'POST_BOOKING_EXTRA_ADDED',
    jsonb_build_object('extra_id',v_row.id,'kind',p_kind,'quantity',p_quantity,
      'unit_price',v_unit,'total',v_total,'balance_before',v_before,'balance_after',v_after,
      'collection_id',v_collection.id,'notification',v_notice),
    'ADMIN_UI',p_admin_id,p_request_id);
  return jsonb_build_object('id',v_row.id,'kind',p_kind,'quantity',p_quantity,'unit_price',v_unit,
    'total',v_total,'balance_before',v_before,'balance_after',v_after,
    'collection_id',v_collection.id,'notification',v_notice,'idempotent_replay',false);
end;
$function$;

revoke all on function public.service_admin_add_post_booking_extra(uuid,text,uuid,integer,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_add_post_booking_extra(uuid,text,uuid,integer,uuid,uuid) to service_role;
