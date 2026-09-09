alter table public.service_waitlist_entries
  add column if not exists preferred_dates date[] not null default '{}'::date[];

create or replace function public.public_create_service_waitlist_entry_v2(
  p_booking_page_slug text,
  p_service_id uuid,
  p_name text,
  p_email text,
  p_whatsapp text,
  p_preferred_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
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
  v_existing_ids uuid[];
  v_changed boolean := false;
  v_notification_key text;
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

  select coalesce(array_agg(w.id order by w.created_at,w.id),'{}'::uuid[])
    into v_existing_ids
  from public.service_waitlist_entries w
  where w.service_id=p_service_id
    and (w.email_normalized=v_email or w.whatsapp_normalized=v_whatsapp_normalized);

  if cardinality(v_existing_ids) > 1 then
    raise exception using errcode='P0001',message='WAITLIST_IDENTITY_CONFLICT';
  end if;

  if cardinality(v_existing_ids)=1 then
    select * into v_entry
    from public.service_waitlist_entries
    where id=v_existing_ids[1]
    for update;

    if p_preferred_date is not null and not (p_preferred_date = any(coalesce(v_entry.preferred_dates,'{}'::date[]))) then
      update public.service_waitlist_entries
      set preferred_dates=(
        select array_agg(d order by d)
        from (
          select distinct unnest(coalesce(v_entry.preferred_dates,'{}'::date[]) || array[p_preferred_date]) as d
        ) q
      )
      where id=v_entry.id
      returning * into v_entry;
      v_changed := true;
    end if;
  else
    select c.id into v_customer_id
    from public.customers c
    where c.anonymized_at is null
      and (
        lower(btrim(coalesce(c.email,'')))=v_email
        or regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')=v_whatsapp_normalized
      )
    order by case when lower(btrim(coalesce(c.email,'')))=v_email then 0 else 1 end,c.created_at,c.id
    limit 1;

    insert into public.service_waitlist_entries(
      booking_page_id,service_id,name,email,email_normalized,whatsapp,whatsapp_normalized,customer_id,preferred_dates
    ) values (
      v_page_id,p_service_id,v_name,v_email,v_email,v_whatsapp,v_whatsapp_normalized,v_customer_id,
      case when p_preferred_date is null then '{}'::date[] else array[p_preferred_date] end
    ) returning * into v_entry;
    v_changed := true;
  end if;

  v_notification_key := 'waitlist:'||v_entry.id::text||':team:'||coalesce(to_char(p_preferred_date,'YYYY-MM-DD'),'general');

  if v_changed then
    insert into public.notification_delivery_logs(
      event_key,channel,audience,customer_id,status,attempt_count,idempotency_key,payload_snapshot
    ) values (
      'WAITLIST_SIGNUP_TEAM','EMAIL','EMPLOYEE',v_entry.customer_id,'PENDING',0,
      v_notification_key,
      jsonb_build_object(
        'waitlist_entry_id',v_entry.id,
        'service_id',p_service_id,
        'service_name',v_service_name,
        'operation_scope',v_operation_scope,
        'name',v_entry.name,
        'email',v_entry.email,
        'whatsapp',v_entry.whatsapp,
        'preferred_dates',v_entry.preferred_dates,
        'created_at',v_entry.created_at
      )
    ) on conflict (idempotency_key) do nothing;
  end if;

  return jsonb_build_object(
    'id',v_entry.id,
    'service_id',p_service_id,
    'service_name',v_service_name,
    'operation_scope',v_operation_scope,
    'customer_id',v_entry.customer_id,
    'preferred_dates',to_jsonb(v_entry.preferred_dates),
    'preferred_date_added',v_changed,
    'created_at',v_entry.created_at,
    'notification_idempotency_key',v_notification_key
  );
end;
$function$;

revoke all on function public.public_create_service_waitlist_entry_v2(text,uuid,text,text,text,date) from public,anon,authenticated;
grant execute on function public.public_create_service_waitlist_entry_v2(text,uuid,text,text,text,date) to service_role;

update public.notification_template_configs
set variable_schema = case
      when variable_schema @> '["waitlist.preferred_dates"]'::jsonb then variable_schema
      else variable_schema || '["waitlist.preferred_dates"]'::jsonb
    end,
    body_template = case
      when body_template like '%{{waitlist.preferred_dates}}%' then body_template
      else replace(body_template,'Inscrição: {{waitlist.created_at}}','Data(s) de interesse: {{waitlist.preferred_dates}}\nInscrição: {{waitlist.created_at}}')
    end,
    updated_at = now()
where event_key='WAITLIST_SIGNUP_TEAM' and is_active;