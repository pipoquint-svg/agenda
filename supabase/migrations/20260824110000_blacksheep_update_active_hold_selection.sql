create or replace function public.public_update_checkout_hold_selection(
  p_checkout_hold_token text,
  p_extra_selections jsonb,
  p_people_count integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_page_slug text;
  v_service public.services%rowtype;
  v_quote jsonb;
  v_canonical_extras jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_new_pre integer;
  v_new_post integer;
  v_new_contracted integer;
  v_selection_hash text;
begin
  if p_checkout_hold_token is null or btrim(p_checkout_hold_token) = '' then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  select * into v_service from public.services where id=v_hold.service_id and is_active;
  if not found then
    raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE';
  end if;
  if coalesce(v_service.operation_scope,'') <> 'BLACKSHEEP' then
    raise exception using errcode='P0001', message='HOLD_SELECTION_UPDATE_NOT_ALLOWED';
  end if;

  select bp.slug into v_page_slug
  from public.booking_pages bp
  where bp.id=v_hold.booking_page_id and bp.is_active;
  if v_page_slug is null then
    raise exception using errcode='P0001', message='CHECKOUT_ORIGIN_NOT_ACTIVE';
  end if;

  if exists (
    select 1 from public.checkout_hour_package_reservations phr
    where phr.checkout_hold_id=v_hold.id and phr.status='HELD'
  ) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_LOCKED';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id',x.extra_id,'quantity',x.quantity) order by x.extra_id
  ),'[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) x(extra_id uuid,quantity integer);

  perform public.assert_public_booking_duration(
    v_page_slug,
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count
  );

  v_new_contracted := public.resolve_service_contracted_minutes(v_hold.service_id,v_hold.duration_blocks);
  v_quote := public.calculate_booking_quote_for_duration(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count,
    v_hold.core_start_at,
    null
  );

  v_new_pre := coalesce((v_quote->>'pre_service_minutes')::integer,0);
  v_new_post := coalesce((v_quote->>'post_service_minutes')::integer,0);

  if v_new_contracted <> v_hold.contracted_minutes
     or v_new_pre <> coalesce(v_hold.pre_service_minutes,0)
     or v_new_post <> coalesce(v_hold.post_service_minutes,0) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_REQUIRES_NEW_SLOT';
  end if;

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_hold.service_id,
    v_canonical_extras,
    v_hold.core_start_at,
    v_hold.duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001', message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  delete from public.resource_allocations
  where checkout_hold_id=v_hold.id
    and allocation_type='CHECKOUT_HOLD'
    and status='HELD';

  begin
    insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
    select r.resource_id,v_hold.id,'CHECKOUT_HOLD','HELD',r.occupied_range
    from public.calculate_booking_resource_ranges_for_duration(
      v_hold.service_id,
      v_canonical_extras,
      v_hold.core_start_at,
      v_hold.duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode='P0001', message='RESOURCE_NOT_AVAILABLE';
  end;

  v_selection_hash := md5(concat_ws('|',
    v_hold.service_id::text,
    v_hold.service_employee_id::text,
    coalesce(v_hold.duration_blocks::text,'FIXED'),
    v_canonical_extras::text,
    p_people_count::text,
    v_hold.requested_start_at::text,
    v_hold.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  update public.checkout_holds
  set people_count=p_people_count,
      extra_selections=v_canonical_extras,
      commercial_value=(v_quote->>'commercial_value')::numeric(12,2),
      pricing_version=v_quote->>'pricing_version',
      quote_snapshot=v_quote,
      resource_ids=v_resource_ids,
      selection_hash=v_selection_hash,
      schedule_profile=v_quote->'schedule_profile',
      updated_at=now()
  where id=v_hold.id;

  return public.public_get_checkout_context(p_checkout_hold_token);
end;
$function$;

revoke all on function public.public_update_checkout_hold_selection(text,jsonb,integer) from public, anon, authenticated;
grant execute on function public.public_update_checkout_hold_selection(text,jsonb,integer) to service_role;
