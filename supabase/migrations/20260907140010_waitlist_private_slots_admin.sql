create or replace function public.service_admin_create_waitlist_private_slot(
  p_start_at timestamptz,
  p_expires_at timestamptz,
  p_service_ids uuid[],
  p_waitlist_entry_ids uuid[],
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_slot_id uuid := gen_random_uuid();
  v_page_id uuid;
  v_page_slug text;
  v_service_id uuid;
  v_employee_count integer;
  v_service_employee_id uuid;
  v_first_resources uuid[];
  v_resources uuid[];
  v_resource record;
  v_allocation_id uuid;
  v_entry record;
  v_raw_token text;
  v_token_hash text;
  v_invite_id uuid;
  v_invites jsonb := '[]'::jsonb;
  v_distinct_services integer;
  v_distinct_entries integer;
begin
  if not public.service_admin_has_permission(p_admin_id, 'WAITLIST_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_waitlist_private_slots();

  if p_start_at is null or p_start_at <= now() then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_START_INVALID';
  end if;
  if p_expires_at is null or p_expires_at <= now() or p_expires_at > p_start_at then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_EXPIRY_INVALID';
  end if;
  if coalesce(array_length(p_service_ids,1),0) < 1 then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_SERVICES_REQUIRED';
  end if;
  if coalesce(array_length(p_waitlist_entry_ids,1),0) < 1 then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_INVITEES_REQUIRED';
  end if;

  select count(distinct x) into v_distinct_services from unnest(p_service_ids) x;
  if v_distinct_services <> array_length(p_service_ids,1) then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_SERVICE_DUPLICATE';
  end if;
  select count(distinct x) into v_distinct_entries from unnest(p_waitlist_entry_ids) x;
  if v_distinct_entries <> array_length(p_waitlist_entry_ids,1) then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_INVITEE_DUPLICATE';
  end if;

  select bp.id, bp.slug
  into v_page_id, v_page_slug
  from public.booking_pages bp
  join public.booking_page_services bps on bps.booking_page_id=bp.id and bps.is_active
  join public.services s on s.id=bps.service_id and s.is_active
  where s.id = any(p_service_ids)
    and s.duration_mode = 'FIXED'
    and bp.is_active
  order by bp.id
  limit 1;

  if v_page_id is null or (
    select count(distinct bp.id)
    from public.booking_pages bp
    join public.booking_page_services bps on bps.booking_page_id=bp.id and bps.is_active
    where bps.service_id = any(p_service_ids)
      and bp.is_active
  ) <> 1 then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_BOOKING_PAGE_MISMATCH';
  end if;

  if (
    select count(*)
    from public.services s
    where s.id = any(p_service_ids)
      and s.is_active
      and s.duration_mode='FIXED'
  ) <> v_distinct_services then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_SERVICE_INVALID';
  end if;

  if exists (
    select 1
    from unnest(p_waitlist_entry_ids) x(id)
    left join public.service_waitlist_entries w on w.id=x.id
    where w.id is null or not (w.service_id = any(p_service_ids))
  ) then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_INVITEE_NOT_ELIGIBLE';
  end if;

  insert into public.waitlist_private_slots(
    id, booking_page_id, start_at, expires_at, status, created_by_admin_id
  ) values (
    v_slot_id, v_page_id, p_start_at, p_expires_at, 'OPEN', p_admin_id
  );

  foreach v_service_id in array p_service_ids
  loop
    select count(*), (array_agg(se.id order by se.id))[1]
    into v_employee_count, v_service_employee_id
    from public.service_employees se
    join public.employees e on e.id=se.employee_id and e.is_active
    where se.service_id=v_service_id and se.is_active;

    if v_employee_count <> 1 or v_service_employee_id is null then
      raise exception using errcode='P0001', message='WAITLIST_PRIVATE_EMPLOYEE_AMBIGUOUS';
    end if;

    insert into public.waitlist_private_slot_services(slot_id,service_id,service_employee_id)
    values(v_slot_id,v_service_id,v_service_employee_id);

    select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
    into v_resources
    from public.calculate_booking_resource_ranges(v_service_id,'[]'::jsonb,p_start_at) r;

    if coalesce(array_length(v_resources,1),0)=0 then
      raise exception using errcode='P0001', message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
    end if;

    if v_first_resources is null then
      v_first_resources := v_resources;
    elsif v_first_resources is distinct from v_resources then
      raise exception using errcode='P0001', message='WAITLIST_PRIVATE_SERVICE_RESOURCE_MISMATCH';
    end if;
  end loop;

  for v_resource in
    with all_ranges as (
      select r.resource_id, r.occupied_range
      from unnest(p_service_ids) s(service_id)
      cross join lateral public.calculate_booking_resource_ranges(
        s.service_id,'[]'::jsonb,p_start_at
      ) r
    )
    select resource_id,
           tstzrange(min(lower(occupied_range)),max(upper(occupied_range)),'[)') as occupied_range
    from all_ranges
    group by resource_id
    order by resource_id
  loop
    insert into public.resource_allocations(
      resource_id, allocation_type, status, occupied_range, reason, created_by_admin_id
    ) values (
      v_resource.resource_id, 'MANUAL_BLOCK', 'BLOCKED', v_resource.occupied_range,
      'WAITLIST_PRIVATE_SLOT:'||v_slot_id::text, p_admin_id
    ) returning id into v_allocation_id;

    insert into public.waitlist_private_slot_resources(
      slot_id,resource_id,allocation_id,occupied_range_snapshot
    ) values (
      v_slot_id,v_resource.resource_id,v_allocation_id,v_resource.occupied_range
    );
  end loop;

  for v_entry in
    select w.id,w.name,w.whatsapp,w.email
    from public.service_waitlist_entries w
    where w.id = any(p_waitlist_entry_ids)
    order by w.created_at,w.id
  loop
    v_raw_token := encode(gen_random_bytes(32),'hex');
    v_token_hash := encode(digest(v_raw_token,'sha256'),'hex');

    insert into public.waitlist_private_invites(
      slot_id,waitlist_entry_id,token_hash,expires_at,created_by_admin_id
    ) values (
      v_slot_id,v_entry.id,v_token_hash,p_expires_at,p_admin_id
    ) returning id into v_invite_id;

    v_invites := v_invites || jsonb_build_array(jsonb_build_object(
      'invite_id',v_invite_id,
      'waitlist_entry_id',v_entry.id,
      'name',v_entry.name,
      'whatsapp',v_entry.whatsapp,
      'email',v_entry.email,
      'access_token',v_raw_token
    ));
  end loop;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(
    p_admin_id,'WAITLIST_PRIVATE_SLOT',v_slot_id,'WAITLIST_PRIVATE_SLOT_CREATED',
    jsonb_build_object(
      'start_at',p_start_at,'expires_at',p_expires_at,'booking_page_slug',v_page_slug,
      'service_ids',to_jsonb(p_service_ids),'invite_count',jsonb_array_length(v_invites)
    ),
    'ADMIN_UI'
  );

  return jsonb_build_object(
    'slot',jsonb_build_object(
      'id',v_slot_id,'start_at',p_start_at,'expires_at',p_expires_at,
      'status','OPEN','booking_page_slug',v_page_slug
    ),
    'invites',v_invites
  );
exception
  when exclusion_violation then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_CONFLICT';
end;
$function$;

create or replace function public.service_admin_list_waitlist_private_slots(p_admin_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_VIEW') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_waitlist_private_slots();

  select coalesce(jsonb_agg(item order by (item->>'start_at')::timestamptz desc),'[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id',s.id,
      'start_at',s.start_at,
      'expires_at',s.expires_at,
      'status',s.status,
      'filled_at',s.filled_at,
      'booking_page_slug',bp.slug,
      'claimed_checkout_hold_id',s.claimed_checkout_hold_id,
      'claimed_appointment_id',s.claimed_appointment_id,
      'services',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',svc.id,'name',svc.name,'base_price',svc.base_price
        ) order by svc.base_price,svc.name)
        from public.waitlist_private_slot_services ss
        join public.services svc on svc.id=ss.service_id
        where ss.slot_id=s.id
      ),'[]'::jsonb),
      'invites',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',i.id,
          'waitlist_entry_id',i.waitlist_entry_id,
          'name',w.name,
          'whatsapp',w.whatsapp,
          'email',w.email,
          'opened_at',i.opened_at,
          'revoked_at',i.revoked_at,
          'expires_at',i.expires_at,
          'checkout_hold_id',i.checkout_hold_id,
          'appointment_id',i.appointment_id
        ) order by w.name,i.id)
        from public.waitlist_private_invites i
        join public.service_waitlist_entries w on w.id=i.waitlist_entry_id
        where i.slot_id=s.id
      ),'[]'::jsonb)
    ) item
    from public.waitlist_private_slots s
    join public.booking_pages bp on bp.id=s.booking_page_id
    order by s.start_at desc
    limit 100
  ) q;

  return v_result;
end;
$function$;

create or replace function public.service_admin_rotate_waitlist_private_invite(
  p_invite_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_invite public.waitlist_private_invites%rowtype;
  v_slot public.waitlist_private_slots%rowtype;
  v_entry public.service_waitlist_entries%rowtype;
  v_raw_token text;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_invite from public.waitlist_private_invites where id=p_invite_id for update;
  if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_NOT_FOUND'; end if;
  select * into v_slot from public.waitlist_private_slots where id=v_invite.slot_id for update;
  if v_slot.status not in ('OPEN','CLAIMED') or v_slot.expires_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_AVAILABLE';
  end if;
  if v_invite.appointment_id is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_ALREADY_USED';
  end if;

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  update public.waitlist_private_invites
  set token_hash=encode(digest(v_raw_token,'sha256'),'hex'),
      expires_at=v_slot.expires_at,
      revoked_at=null,
      updated_at=now()
  where id=v_invite.id;

  select * into v_entry from public.service_waitlist_entries where id=v_invite.waitlist_entry_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'WAITLIST_PRIVATE_INVITE',v_invite.id,'WAITLIST_PRIVATE_INVITE_TOKEN_ROTATED',
    jsonb_build_object('slot_id',v_slot.id),'ADMIN_UI');

  return jsonb_build_object(
    'invite_id',v_invite.id,'name',v_entry.name,'whatsapp',v_entry.whatsapp,
    'email',v_entry.email,'access_token',v_raw_token,'expires_at',v_slot.expires_at
  );
end;
$function$;

create or replace function public.service_admin_revoke_waitlist_private_invite(
  p_invite_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_invite public.waitlist_private_invites%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select * into v_invite from public.waitlist_private_invites where id=p_invite_id for update;
  if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_NOT_FOUND'; end if;
  if v_invite.checkout_hold_id is not null or v_invite.appointment_id is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_IN_PROGRESS';
  end if;
  update public.waitlist_private_invites
  set revoked_at=coalesce(revoked_at,now()),updated_at=now()
  where id=p_invite_id;
  return jsonb_build_object('invite_id',p_invite_id,'revoked',true);
end;
$function$;

create or replace function public.service_admin_extend_waitlist_private_slot(
  p_slot_id uuid,
  p_expires_at timestamptz,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_slot public.waitlist_private_slots%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select * into v_slot from public.waitlist_private_slots where id=p_slot_id for update;
  if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_FOUND'; end if;
  if v_slot.status not in ('OPEN','CLAIMED') then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_AVAILABLE';
  end if;
  if p_expires_at is null or p_expires_at<=now() or p_expires_at>v_slot.start_at then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_EXPIRY_INVALID';
  end if;

  update public.waitlist_private_slots
  set expires_at=p_expires_at,updated_at=now()
  where id=p_slot_id;
  update public.waitlist_private_invites
  set expires_at=p_expires_at,updated_at=now()
  where slot_id=p_slot_id and revoked_at is null and appointment_id is null;

  return jsonb_build_object('slot_id',p_slot_id,'expires_at',p_expires_at);
end;
$function$;

create or replace function public.service_admin_close_waitlist_private_slot(
  p_slot_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_slot public.waitlist_private_slots%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select * into v_slot from public.waitlist_private_slots where id=p_slot_id for update;
  if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_FOUND'; end if;
  if v_slot.status='CLAIMED' then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_BUSY';
  end if;
  if v_slot.status in ('FILLED','CLOSED','EXPIRED') then
    return jsonb_build_object('slot_id',p_slot_id,'status',v_slot.status);
  end if;

  update public.waitlist_private_slots
  set status='CLOSED',closed_at=now(),updated_at=now()
  where id=p_slot_id;

  update public.resource_allocations ra
  set status='RELEASED',updated_at=now()
  from public.waitlist_private_slot_resources sr
  where sr.slot_id=p_slot_id
    and sr.allocation_id=ra.id
    and ra.allocation_type='MANUAL_BLOCK'
    and ra.status='BLOCKED';

  update public.waitlist_private_invites
  set revoked_at=coalesce(revoked_at,now()),updated_at=now()
  where slot_id=p_slot_id and appointment_id is null;

  return jsonb_build_object('slot_id',p_slot_id,'status','CLOSED');
end;
$function$;
