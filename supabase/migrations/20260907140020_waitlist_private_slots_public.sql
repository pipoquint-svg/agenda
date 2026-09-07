create or replace function public.public_get_waitlist_private_invite_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hash text;
  v_invite public.waitlist_private_invites%rowtype;
  v_slot public.waitlist_private_slots%rowtype;
  v_entry public.service_waitlist_entries%rowtype;
  v_page public.booking_pages%rowtype;
  v_availability text;
  v_services jsonb;
begin
  perform public.service_expire_waitlist_private_slots();
  perform public.expire_due_checkout_holds();

  if p_access_token is null or length(btrim(p_access_token))<32 then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  v_hash:=encode(digest(btrim(p_access_token),'sha256'),'hex');

  select * into v_invite
  from public.waitlist_private_invites
  where token_hash=v_hash
  for update;

  if not found or v_invite.revoked_at is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  if v_invite.expires_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_EXPIRED';
  end if;

  select * into v_slot from public.waitlist_private_slots where id=v_invite.slot_id;
  select * into v_entry from public.service_waitlist_entries where id=v_invite.waitlist_entry_id;
  select * into v_page from public.booking_pages where id=v_slot.booking_page_id;

  update public.waitlist_private_invites
  set opened_at=coalesce(opened_at,now()),updated_at=now()
  where id=v_invite.id;

  v_availability := case
    when v_slot.status='FILLED' then 'FILLED'
    when v_slot.status in ('CLOSED','EXPIRED') then 'UNAVAILABLE'
    when v_slot.status='CLAIMED' and (
      v_slot.claimed_checkout_hold_id=v_invite.checkout_hold_id
      or v_slot.claimed_appointment_id=v_invite.appointment_id
    ) then 'IN_PROGRESS'
    when v_slot.status='CLAIMED' then 'CLAIMED'
    else 'OPEN'
  end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,
    'name',s.name,
    'base_price',s.base_price,
    'minimum_people',s.minimum_people,
    'maximum_people',s.maximum_people,
    'service_employee_id',ss.service_employee_id,
    'extras',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,'name',e.name,'description',e.description,'price',e.price,
        'is_required',se.is_required,'max_quantity',se.max_quantity
      ) order by se.sort_order,e.name)
      from public.service_extras se
      join public.extras e on e.id=se.extra_id and e.is_active
      where se.service_id=s.id
    ),'[]'::jsonb)
  ) order by s.base_price,s.name),'[]'::jsonb)
  into v_services
  from public.waitlist_private_slot_services ss
  join public.services s on s.id=ss.service_id
  where ss.slot_id=v_slot.id;

  return jsonb_build_object(
    'invite_id',v_invite.id,
    'slot_id',v_slot.id,
    'invitee_name',v_entry.name,
    'start_at',v_slot.start_at,
    'expires_at',v_invite.expires_at,
    'slot_status',v_slot.status,
    'availability',v_availability,
    'booking_page_slug',v_page.slug,
    'brand_key',v_page.brand_key,
    'services',v_services
  );
end;
$function$;

create or replace function public.public_create_waitlist_private_checkout_hold(
  p_access_token text,
  p_service_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hash text;
  v_invite public.waitlist_private_invites%rowtype;
  v_slot public.waitlist_private_slots%rowtype;
  v_page public.booking_pages%rowtype;
  v_service public.services%rowtype;
  v_service_employee_id uuid;
  v_quote jsonb;
  v_profile jsonb;
  v_canonical_extras jsonb;
  v_resource_ids uuid[];
  v_slot_resource_ids uuid[];
  v_core_duration integer;
  v_pre integer;
  v_post integer;
  v_requested_start timestamptz;
  v_requested_end timestamptz;
  v_core_end timestamptz;
  v_hold_minutes integer;
  v_hold_expires_at timestamptz;
  v_hold_id uuid := gen_random_uuid();
  v_raw_hold_token text;
  v_hold_token_hash text;
  v_selection_hash text;
  v_bad_range integer;
begin
  perform public.expire_due_checkout_holds();
  perform public.service_expire_waitlist_private_slots();

  if p_access_token is null or length(btrim(p_access_token))<32 then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  v_hash:=encode(digest(btrim(p_access_token),'sha256'),'hex');

  select * into v_invite
  from public.waitlist_private_invites
  where token_hash=v_hash
  for update;
  if not found or v_invite.revoked_at is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  if v_invite.expires_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_EXPIRED';
  end if;

  select * into v_slot
  from public.waitlist_private_slots
  where id=v_invite.slot_id
  for update;
  if v_slot.status <> 'OPEN' then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_TAKEN';
  end if;
  if v_slot.expires_at<=now() or v_slot.start_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_AVAILABLE';
  end if;

  select * into v_page from public.booking_pages where id=v_slot.booking_page_id and is_active;
  if not found then raise exception using errcode='P0001',message='BOOKING_PAGE_NOT_FOUND'; end if;

  select ss.service_employee_id into v_service_employee_id
  from public.waitlist_private_slot_services ss
  where ss.slot_id=v_slot.id and ss.service_id=p_service_id;
  if not found then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SERVICE_NOT_ALLOWED';
  end if;

  select * into v_service from public.services where id=p_service_id and is_active;
  if not found then raise exception using errcode='P0001',message='SERVICE_NOT_AVAILABLE'; end if;

  perform public.assert_public_booking_selection(
    v_page.slug,p_service_id,v_service_employee_id,
    coalesce(p_extra_selections,'[]'::jsonb),p_people_count
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'extra_id',x.extra_id,'quantity',x.quantity
  ) order by x.extra_id),'[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) x(extra_id uuid,quantity integer);

  v_quote:=public.calculate_booking_quote(
    p_service_id,v_service_employee_id,v_canonical_extras,p_people_count,v_slot.start_at,null
  );
  v_profile:=coalesce(v_quote->'schedule_profile','{}'::jsonb);
  v_core_duration:=coalesce((v_quote->>'core_duration_minutes')::integer,v_service.base_duration_minutes);
  v_pre:=coalesce((v_quote->>'pre_service_minutes')::integer,0);
  v_post:=coalesce((v_quote->>'post_service_minutes')::integer,0);
  v_requested_start:=v_slot.start_at-make_interval(mins=>v_pre);
  v_core_end:=v_slot.start_at+make_interval(mins=>v_core_duration);
  v_requested_end:=v_core_end+make_interval(mins=>v_post);

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges(
    p_service_id,v_canonical_extras,v_slot.start_at
  ) r;

  select coalesce(array_agg(sr.resource_id order by sr.resource_id),'{}'::uuid[])
  into v_slot_resource_ids
  from public.waitlist_private_slot_resources sr
  where sr.slot_id=v_slot.id;

  if v_resource_ids is distinct from v_slot_resource_ids then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SELECTION_RESOURCE_MISMATCH';
  end if;

  select count(*)::integer into v_bad_range
  from public.calculate_booking_resource_ranges(
    p_service_id,v_canonical_extras,v_slot.start_at
  ) r
  join public.waitlist_private_slot_resources sr
    on sr.slot_id=v_slot.id and sr.resource_id=r.resource_id
  where not (r.occupied_range <@ sr.occupied_range_snapshot);

  if v_bad_range>0 then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SELECTION_RANGE_MISMATCH';
  end if;

  select coalesce(v_service.checkout_hold_minutes,os.checkout_hold_minutes)
  into v_hold_minutes
  from public.operation_settings os
  where os.id=1;

  v_hold_expires_at:=least(now()+make_interval(mins=>v_hold_minutes),v_slot.start_at);
  if v_hold_expires_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_AVAILABLE';
  end if;

  v_raw_hold_token:=encode(gen_random_bytes(32),'hex');
  v_hold_token_hash:=encode(digest(v_raw_hold_token,'sha256'),'hex');
  v_selection_hash:=md5(concat_ws('|',
    p_service_id::text,v_service_employee_id::text,v_canonical_extras::text,
    p_people_count::text,v_slot.start_at::text,v_quote->>'pricing_version',
    'PRIVATE_WAITLIST',v_slot.id::text
  ));

  insert into public.checkout_holds(
    id,public_token_hash,service_id,service_employee_id,selection_hash,people_count,
    requested_start_at,requested_end_at,core_start_at,core_end_at,
    pre_service_minutes,post_service_minutes,schedule_profile,status,expires_at,
    extra_selections,commercial_value,pricing_version,duration_minutes,resource_ids,
    booking_page_id,attribution_json,quote_snapshot
  ) values (
    v_hold_id,v_hold_token_hash,p_service_id,v_service_employee_id,v_selection_hash,p_people_count,
    v_requested_start,v_requested_end,v_slot.start_at,v_core_end,
    v_pre,v_post,v_profile,'ACTIVE',v_hold_expires_at,
    v_canonical_extras,(v_quote->>'commercial_value')::numeric(12,2),
    v_quote->>'pricing_version',v_core_duration+v_pre+v_post,v_resource_ids,
    v_slot.booking_page_id,
    jsonb_build_object('source','WAITLIST_PRIVATE_INVITE','private_slot_id',v_slot.id,'private_invite_id',v_invite.id),
    v_quote
  );

  update public.resource_allocations ra
  set checkout_hold_id=v_hold_id,
      appointment_id=null,
      pre_reservation_id=null,
      allocation_type='CHECKOUT_HOLD',
      status='HELD',
      reason='WAITLIST_PRIVATE_INVITE:'||v_invite.id::text,
      created_by_admin_id=null,
      updated_at=now()
  from public.waitlist_private_slot_resources sr
  where sr.slot_id=v_slot.id
    and sr.allocation_id=ra.id
    and ra.allocation_type='MANUAL_BLOCK'
    and ra.status='BLOCKED';

  if (select count(*) from public.resource_allocations where checkout_hold_id=v_hold_id and allocation_type='CHECKOUT_HOLD' and status='HELD')
     <> coalesce(array_length(v_resource_ids,1),0) then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_RESOURCE_INTEGRITY_ERROR';
  end if;

  update public.waitlist_private_invites
  set checkout_hold_id=v_hold_id,appointment_id=null,updated_at=now()
  where id=v_invite.id;

  update public.waitlist_private_slots
  set status='CLAIMED',claimed_checkout_hold_id=v_hold_id,claimed_appointment_id=null,updated_at=now()
  where id=v_slot.id;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values(
    'WAITLIST_PRIVATE_SLOT',v_slot.id,'WAITLIST_PRIVATE_SLOT_CLAIMED',
    jsonb_build_object('invite_id',v_invite.id,'checkout_hold_id',v_hold_id,'service_id',p_service_id),
    'PUBLIC'
  );

  return jsonb_build_object(
    'checkout_hold_token',v_raw_hold_token,
    'checkout_hold_id',v_hold_id,
    'status','ACTIVE',
    'expires_at',v_hold_expires_at,
    'slot_start_at',v_requested_start,
    'slot_end_at',v_requested_end,
    'core_start_at',v_slot.start_at,
    'core_end_at',v_core_end,
    'pre_service_minutes',v_pre,
    'post_service_minutes',v_post,
    'commercial_value',(v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes',v_core_duration+v_pre+v_post,
    'pricing_version',v_quote->>'pricing_version',
    'booking_page_slug',v_page.slug,
    'service_name',v_service.name
  );
end;
$function$;

revoke all on function public.service_expire_waitlist_private_slots() from public, anon, authenticated;
revoke all on function public.try_restore_waitlist_private_slot(uuid,text) from public, anon, authenticated;
revoke all on function public.service_admin_create_waitlist_private_slot(timestamptz,timestamptz,uuid[],uuid[],uuid) from public, anon, authenticated;
revoke all on function public.service_admin_list_waitlist_private_slots(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_rotate_waitlist_private_invite(uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_revoke_waitlist_private_invite(uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_extend_waitlist_private_slot(uuid,timestamptz,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_close_waitlist_private_slot(uuid,uuid) from public, anon, authenticated;
revoke all on function public.public_get_waitlist_private_invite_context(text) from public, anon, authenticated;
revoke all on function public.public_create_waitlist_private_checkout_hold(text,uuid,jsonb,integer) from public, anon, authenticated;
revoke all on function public.trg_restore_waitlist_private_slot_allocation() from public, anon, authenticated;
revoke all on function public.trg_sync_waitlist_private_checkout_promotion() from public, anon, authenticated;
revoke all on function public.trg_sync_waitlist_private_appointment_status() from public, anon, authenticated;

grant execute on function public.service_expire_waitlist_private_slots() to service_role;
grant execute on function public.try_restore_waitlist_private_slot(uuid,text) to service_role;
grant execute on function public.service_admin_create_waitlist_private_slot(timestamptz,timestamptz,uuid[],uuid[],uuid) to service_role;
grant execute on function public.service_admin_list_waitlist_private_slots(uuid) to service_role;
grant execute on function public.service_admin_rotate_waitlist_private_invite(uuid,uuid) to service_role;
grant execute on function public.service_admin_revoke_waitlist_private_invite(uuid,uuid) to service_role;
grant execute on function public.service_admin_extend_waitlist_private_slot(uuid,timestamptz,uuid) to service_role;
grant execute on function public.service_admin_close_waitlist_private_slot(uuid,uuid) to service_role;
grant execute on function public.public_get_waitlist_private_invite_context(text) to service_role;
grant execute on function public.public_create_waitlist_private_checkout_hold(text,uuid,jsonb,integer) to service_role;

grant select, insert, update, delete on public.waitlist_private_slots to service_role;
grant select, insert, update, delete on public.waitlist_private_slot_services to service_role;
grant select, insert, update, delete on public.waitlist_private_slot_resources to service_role;
grant select, insert, update, delete on public.waitlist_private_invites to service_role;
