-- Private waitlist rounds: one family token can choose among many hidden slots.
-- Existing single-slot invitations remain backwards compatible.

create table public.waitlist_private_rounds (
  id uuid primary key default gen_random_uuid(),
  booking_page_id uuid not null references public.booking_pages(id) on delete restrict,
  expires_at timestamptz not null,
  closed_at timestamptz null,
  created_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create table public.waitlist_private_round_slots (
  round_id uuid not null references public.waitlist_private_rounds(id) on delete cascade,
  slot_id uuid not null unique references public.waitlist_private_slots(id) on delete restrict,
  sort_order integer not null default 0,
  primary key (round_id, slot_id)
);

create table public.waitlist_private_round_invites (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.waitlist_private_rounds(id) on delete cascade,
  waitlist_entry_id uuid not null references public.service_waitlist_entries(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  opened_at timestamptz null,
  revoked_at timestamptz null,
  created_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (round_id, waitlist_entry_id)
);

create index waitlist_private_rounds_expiry_idx
  on public.waitlist_private_rounds(expires_at) where closed_at is null;
create index waitlist_private_round_slots_round_idx
  on public.waitlist_private_round_slots(round_id, sort_order, slot_id);
create index waitlist_private_round_invites_round_idx
  on public.waitlist_private_round_invites(round_id);
create index waitlist_private_round_invites_waitlist_idx
  on public.waitlist_private_round_invites(waitlist_entry_id);

alter table public.waitlist_private_rounds enable row level security;
alter table public.waitlist_private_round_slots enable row level security;
alter table public.waitlist_private_round_invites enable row level security;

revoke all on public.waitlist_private_rounds from anon, authenticated;
revoke all on public.waitlist_private_round_slots from anon, authenticated;
revoke all on public.waitlist_private_round_invites from anon, authenticated;

create or replace function public.service_admin_waitlist_private_round_action(
  p_action text,
  p_payload jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_action text := upper(coalesce(nullif(btrim(p_action),''),'LIST'));
  v_payload jsonb := coalesce(p_payload,'{}'::jsonb);
  v_starts timestamptz[];
  v_start timestamptz;
  v_expires_at timestamptz;
  v_service_ids uuid[];
  v_waitlist_ids uuid[];
  v_round_id uuid := gen_random_uuid();
  v_page_id uuid;
  v_slot_page_id uuid;
  v_slot_id uuid;
  v_slot_result jsonb;
  v_sort integer := 0;
  v_raw_token text;
  v_invite_id uuid;
  v_invites jsonb := '[]'::jsonb;
  v_round_invite public.waitlist_private_round_invites%rowtype;
  v_round public.waitlist_private_rounds%rowtype;
  v_entry public.service_waitlist_entries%rowtype;
  v_result jsonb;
  v_busy_checkout boolean;
  v_busy_appointment boolean;
  v_open_slot record;
begin
  if v_action = 'LIST' then
    if not public.service_admin_has_permission(p_admin_id,'WAITLIST_VIEW') then
      raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
    end if;

    perform public.expire_due_checkout_holds();
    perform public.service_expire_waitlist_private_slots();

    select coalesce(jsonb_agg(item order by (item->>'created_at')::timestamptz desc),'[]'::jsonb)
    into v_result
    from (
      select jsonb_build_object(
        'id',r.id,
        'expires_at',r.expires_at,
        'closed_at',r.closed_at,
        'created_at',r.created_at,
        'booking_page_slug',bp.slug,
        'status',case
          when r.closed_at is not null then 'CLOSED'
          when r.expires_at <= now() then 'EXPIRED'
          when not exists (
            select 1 from public.waitlist_private_round_slots rsx
            join public.waitlist_private_slots sx on sx.id=rsx.slot_id
            where rsx.round_id=r.id and sx.status in ('OPEN','CLAIMED')
          ) then 'FULL'
          else 'OPEN'
        end,
        'total_count',(select count(*) from public.waitlist_private_round_slots rsx where rsx.round_id=r.id),
        'available_count',(select count(*) from public.waitlist_private_round_slots rsx join public.waitlist_private_slots sx on sx.id=rsx.slot_id where rsx.round_id=r.id and sx.status='OPEN'),
        'claimed_count',(select count(*) from public.waitlist_private_round_slots rsx join public.waitlist_private_slots sx on sx.id=rsx.slot_id where rsx.round_id=r.id and sx.status='CLAIMED'),
        'filled_count',(select count(*) from public.waitlist_private_round_slots rsx join public.waitlist_private_slots sx on sx.id=rsx.slot_id where rsx.round_id=r.id and sx.status='FILLED'),
        'services',coalesce((
          select jsonb_agg(jsonb_build_object('id',svc.id,'name',svc.name,'base_price',svc.base_price) order by svc.base_price,svc.name)
          from public.waitlist_private_round_slots rs0
          join public.waitlist_private_slot_services ss on ss.slot_id=rs0.slot_id
          join public.services svc on svc.id=ss.service_id
          where rs0.round_id=r.id
            and rs0.slot_id=(select rs1.slot_id from public.waitlist_private_round_slots rs1 where rs1.round_id=r.id order by rs1.sort_order,rs1.slot_id limit 1)
        ),'[]'::jsonb),
        'slots',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',s.id,'start_at',s.start_at,'expires_at',s.expires_at,'status',s.status,
            'filled_at',s.filled_at,'claimed_checkout_hold_id',s.claimed_checkout_hold_id,
            'claimed_appointment_id',s.claimed_appointment_id
          ) order by rs.sort_order,s.start_at,s.id)
          from public.waitlist_private_round_slots rs
          join public.waitlist_private_slots s on s.id=rs.slot_id
          where rs.round_id=r.id
        ),'[]'::jsonb),
        'invites',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',ri.id,
            'waitlist_entry_id',ri.waitlist_entry_id,
            'name',w.name,
            'whatsapp',w.whatsapp,
            'email',w.email,
            'opened_at',ri.opened_at,
            'revoked_at',ri.revoked_at,
            'expires_at',ri.expires_at,
            'active_slot_id',active.slot_id,
            'checkout_hold_id',active.checkout_hold_id,
            'appointment_id',active.appointment_id,
            'appointment_status',active.appointment_status
          ) order by w.name,ri.id)
          from public.waitlist_private_round_invites ri
          join public.service_waitlist_entries w on w.id=ri.waitlist_entry_id
          left join lateral (
            select i.slot_id,i.checkout_hold_id,i.appointment_id,a.status::text as appointment_status
            from public.waitlist_private_round_slots rs2
            join public.waitlist_private_invites i
              on i.slot_id=rs2.slot_id and i.waitlist_entry_id=ri.waitlist_entry_id
            left join public.appointments a on a.id=i.appointment_id
            where rs2.round_id=r.id
              and (i.checkout_hold_id is not null or i.appointment_id is not null)
            order by (i.appointment_id is not null) desc,i.updated_at desc
            limit 1
          ) active on true
          where ri.round_id=r.id
        ),'[]'::jsonb)
      ) item
      from public.waitlist_private_rounds r
      join public.booking_pages bp on bp.id=r.booking_page_id
      order by r.created_at desc
      limit 50
    ) q;

    return v_result;
  end if;

  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;

  if v_action = 'CREATE' then
    if jsonb_typeof(v_payload->'start_ats') <> 'array' or jsonb_array_length(v_payload->'start_ats') < 1 then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_SLOTS_REQUIRED';
    end if;
    if jsonb_array_length(v_payload->'start_ats') > 30 then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_TOO_MANY_SLOTS';
    end if;

    begin
      select array_agg(x.value::timestamptz order by x.value::timestamptz)
      into v_starts
      from jsonb_array_elements_text(v_payload->'start_ats') x(value);
      v_expires_at := (v_payload->>'expires_at')::timestamptz;
      select array_agg(x.value::uuid order by x.value::uuid)
      into v_service_ids
      from jsonb_array_elements_text(v_payload->'service_ids') x(value);
      select array_agg(x.value::uuid order by x.value::uuid)
      into v_waitlist_ids
      from jsonb_array_elements_text(v_payload->'waitlist_entry_ids') x(value);
    exception when others then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_INPUT_INVALID';
    end;

    if coalesce(array_length(v_service_ids,1),0) < 1 then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SERVICES_REQUIRED';
    end if;
    if coalesce(array_length(v_waitlist_ids,1),0) < 1 then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITEES_REQUIRED';
    end if;
    if array_length(v_waitlist_ids,1) > 250 then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_TOO_MANY_INVITEES';
    end if;
    if (select count(distinct x) from unnest(v_starts) x) <> array_length(v_starts,1) then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_SLOT_DUPLICATE';
    end if;
    if exists (select 1 from unnest(v_starts) x where x <= now()) then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_START_INVALID';
    end if;
    if v_expires_at is null or v_expires_at <= now() or v_expires_at > (select min(x) from unnest(v_starts) x) then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_EXPIRY_INVALID';
    end if;

    foreach v_start in array v_starts loop
      v_slot_result := public.service_admin_create_waitlist_private_slot(
        v_start,v_expires_at,v_service_ids,v_waitlist_ids,p_admin_id
      );
      v_slot_id := (v_slot_result->'slot'->>'id')::uuid;
      select booking_page_id into v_slot_page_id from public.waitlist_private_slots where id=v_slot_id;

      if v_page_id is null then
        v_page_id := v_slot_page_id;
        insert into public.waitlist_private_rounds(
          id,booking_page_id,expires_at,created_by_admin_id
        ) values (
          v_round_id,v_page_id,v_expires_at,p_admin_id
        );
      elsif v_page_id is distinct from v_slot_page_id then
        raise exception using errcode='P0001',message='WAITLIST_PRIVATE_BOOKING_PAGE_MISMATCH';
      end if;

      insert into public.waitlist_private_round_slots(round_id,slot_id,sort_order)
      values(v_round_id,v_slot_id,v_sort);
      v_sort := v_sort + 1;
    end loop;

    for v_entry in
      select w.* from public.service_waitlist_entries w
      where w.id=any(v_waitlist_ids)
      order by w.created_at,w.id
    loop
      v_raw_token := encode(gen_random_bytes(32),'hex');
      insert into public.waitlist_private_round_invites(
        round_id,waitlist_entry_id,token_hash,expires_at,created_by_admin_id
      ) values (
        v_round_id,v_entry.id,encode(digest(v_raw_token,'sha256'),'hex'),v_expires_at,p_admin_id
      ) returning id into v_invite_id;

      v_invites := v_invites || jsonb_build_array(jsonb_build_object(
        'invite_id',v_invite_id,'waitlist_entry_id',v_entry.id,'name',v_entry.name,
        'whatsapp',v_entry.whatsapp,'email',v_entry.email,'access_token',v_raw_token,
        'expires_at',v_expires_at
      ));
    end loop;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
    values(
      p_admin_id,'WAITLIST_PRIVATE_ROUND',v_round_id,'WAITLIST_PRIVATE_ROUND_CREATED',
      jsonb_build_object('slot_count',array_length(v_starts,1),'invite_count',jsonb_array_length(v_invites),'expires_at',v_expires_at),
      'ADMIN_UI'
    );

    return jsonb_build_object(
      'round',jsonb_build_object(
        'id',v_round_id,'expires_at',v_expires_at,'status','OPEN',
        'booking_page_slug',(select slug from public.booking_pages where id=v_page_id),
        'slots',(select jsonb_agg(jsonb_build_object('id',s.id,'start_at',s.start_at,'status',s.status) order by rs.sort_order,s.start_at)
                 from public.waitlist_private_round_slots rs join public.waitlist_private_slots s on s.id=rs.slot_id where rs.round_id=v_round_id)
      ),
      'invites',v_invites
    );
  end if;

  if v_action in ('ROTATE_INVITE','REVOKE_INVITE') then
    select * into v_round_invite
    from public.waitlist_private_round_invites
    where id=(v_payload->>'invite_id')::uuid
    for update;
    if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_INVITE_NOT_FOUND'; end if;

    select * into v_round from public.waitlist_private_rounds where id=v_round_invite.round_id for update;
    if v_round.closed_at is not null or v_round.expires_at<=now() then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_NOT_AVAILABLE';
    end if;

    select exists(
      select 1 from public.waitlist_private_round_slots rs
      join public.waitlist_private_invites i on i.slot_id=rs.slot_id and i.waitlist_entry_id=v_round_invite.waitlist_entry_id
      where rs.round_id=v_round.id and i.checkout_hold_id is not null
    ), exists(
      select 1 from public.waitlist_private_round_slots rs
      join public.waitlist_private_invites i on i.slot_id=rs.slot_id and i.waitlist_entry_id=v_round_invite.waitlist_entry_id
      where rs.round_id=v_round.id and i.appointment_id is not null
    ) into v_busy_checkout,v_busy_appointment;

    if v_busy_appointment then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_ALREADY_USED'; end if;
    if v_busy_checkout then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_IN_PROGRESS'; end if;

    if v_action='REVOKE_INVITE' then
      update public.waitlist_private_round_invites
      set revoked_at=coalesce(revoked_at,now()),updated_at=now()
      where id=v_round_invite.id;
      return jsonb_build_object('invite_id',v_round_invite.id,'revoked',true);
    end if;

    v_raw_token := encode(gen_random_bytes(32),'hex');
    update public.waitlist_private_round_invites
    set token_hash=encode(digest(v_raw_token,'sha256'),'hex'),
        revoked_at=null,expires_at=v_round.expires_at,updated_at=now()
    where id=v_round_invite.id;
    select * into v_entry from public.service_waitlist_entries where id=v_round_invite.waitlist_entry_id;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
    values(p_admin_id,'WAITLIST_PRIVATE_ROUND_INVITE',v_round_invite.id,'WAITLIST_PRIVATE_ROUND_INVITE_TOKEN_ROTATED',
      jsonb_build_object('round_id',v_round.id),'ADMIN_UI');

    return jsonb_build_object(
      'invite_id',v_round_invite.id,'waitlist_entry_id',v_entry.id,'name',v_entry.name,
      'whatsapp',v_entry.whatsapp,'email',v_entry.email,'access_token',v_raw_token,
      'expires_at',v_round.expires_at,'round_id',v_round.id
    );
  end if;

  if v_action='CLOSE' then
    select * into v_round from public.waitlist_private_rounds
    where id=(v_payload->>'round_id')::uuid for update;
    if not found then raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_NOT_FOUND'; end if;
    if v_round.closed_at is not null then
      return jsonb_build_object('round_id',v_round.id,'status','CLOSED');
    end if;
    if exists(
      select 1 from public.waitlist_private_round_slots rs
      join public.waitlist_private_slots s on s.id=rs.slot_id
      where rs.round_id=v_round.id and s.status='CLAIMED'
    ) then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_BUSY';
    end if;

    for v_open_slot in
      select s.id from public.waitlist_private_round_slots rs
      join public.waitlist_private_slots s on s.id=rs.slot_id
      where rs.round_id=v_round.id and s.status='OPEN'
    loop
      perform public.service_admin_close_waitlist_private_slot(v_open_slot.id,p_admin_id);
    end loop;

    update public.waitlist_private_rounds set closed_at=now(),updated_at=now() where id=v_round.id;
    return jsonb_build_object('round_id',v_round.id,'status','CLOSED');
  end if;

  raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ACTION_INVALID';
end;
$function$;

create or replace function public.public_waitlist_private_round_action(
  p_action text,
  p_access_token text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_action text := upper(coalesce(nullif(btrim(p_action),''),'CONTEXT'));
  v_hash text;
  v_round_invite public.waitlist_private_round_invites%rowtype;
  v_round public.waitlist_private_rounds%rowtype;
  v_entry public.service_waitlist_entries%rowtype;
  v_page public.booking_pages%rowtype;
  v_active record;
  v_services jsonb;
  v_slots jsonb;
  v_invite_state text;
  v_slot_id uuid;
  v_underlying_invite public.waitlist_private_invites%rowtype;
  v_raw_slot_token text;
  v_service_id uuid;
  v_extras jsonb;
  v_people_count integer;
  v_hold jsonb;
begin
  perform public.expire_due_checkout_holds();
  perform public.service_expire_waitlist_private_slots();

  if p_access_token is null or length(btrim(p_access_token))<32 then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  v_hash := encode(digest(btrim(p_access_token),'sha256'),'hex');

  select * into v_round_invite
  from public.waitlist_private_round_invites
  where token_hash=v_hash
  for update;

  if not found then
    if v_action='CONTEXT' then return null; end if;
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  if v_round_invite.revoked_at is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_INVALID';
  end if;
  if v_round_invite.expires_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_TOKEN_EXPIRED';
  end if;

  select * into v_round from public.waitlist_private_rounds where id=v_round_invite.round_id for update;
  select * into v_entry from public.service_waitlist_entries where id=v_round_invite.waitlist_entry_id;
  select * into v_page from public.booking_pages where id=v_round.booking_page_id;

  select i.slot_id,i.checkout_hold_id,i.appointment_id,a.status::text as appointment_status
  into v_active
  from public.waitlist_private_round_slots rs
  join public.waitlist_private_invites i
    on i.slot_id=rs.slot_id and i.waitlist_entry_id=v_round_invite.waitlist_entry_id
  left join public.appointments a on a.id=i.appointment_id
  where rs.round_id=v_round.id
    and (i.checkout_hold_id is not null or i.appointment_id is not null)
  order by (i.appointment_id is not null) desc,i.updated_at desc
  limit 1;

  if v_action='CONTEXT' then
    update public.waitlist_private_round_invites
    set opened_at=coalesce(opened_at,now()),updated_at=now()
    where id=v_round_invite.id;

    v_invite_state := case
      when v_active.appointment_id is not null and v_active.appointment_status='CONFIRMED' then 'BOOKED'
      when v_active.appointment_id is not null or v_active.checkout_hold_id is not null then 'IN_PROGRESS'
      when v_round.closed_at is not null or v_round.expires_at<=now() then 'UNAVAILABLE'
      when exists(
        select 1 from public.waitlist_private_round_slots rs
        join public.waitlist_private_slots s on s.id=rs.slot_id
        where rs.round_id=v_round.id and s.status='OPEN'
      ) then 'OPEN'
      else 'NO_AVAILABLE'
    end;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'base_price',s.base_price,
      'minimum_people',s.minimum_people,'maximum_people',s.maximum_people,
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
    from public.waitlist_private_round_slots rs0
    join public.waitlist_private_slot_services ss on ss.slot_id=rs0.slot_id
    join public.services s on s.id=ss.service_id
    where rs0.round_id=v_round.id
      and rs0.slot_id=(select rs1.slot_id from public.waitlist_private_round_slots rs1 where rs1.round_id=v_round.id order by rs1.sort_order,rs1.slot_id limit 1);

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',s.id,
      'start_at',s.start_at,
      'status',s.status,
      'availability',case
        when v_active.slot_id=s.id and v_active.appointment_id is not null and v_active.appointment_status='CONFIRMED' then 'BOOKED'
        when v_active.slot_id=s.id and (v_active.appointment_id is not null or v_active.checkout_hold_id is not null) then 'IN_PROGRESS'
        when v_active.slot_id is not null then 'LOCKED'
        when s.status='OPEN' then 'OPEN'
        when s.status='CLAIMED' then 'CLAIMED'
        when s.status='FILLED' then 'FILLED'
        else 'UNAVAILABLE'
      end
    ) order by rs.sort_order,s.start_at,s.id),'[]'::jsonb)
    into v_slots
    from public.waitlist_private_round_slots rs
    join public.waitlist_private_slots s on s.id=rs.slot_id
    where rs.round_id=v_round.id;

    return jsonb_build_object(
      'mode','ROUND','invite_id',v_round_invite.id,'round_id',v_round.id,
      'invitee_name',v_entry.name,'expires_at',v_round_invite.expires_at,
      'availability',v_invite_state,'active_slot_id',v_active.slot_id,
      'checkout_hold_id',v_active.checkout_hold_id,'appointment_id',v_active.appointment_id,
      'appointment_status',v_active.appointment_status,
      'booking_page_slug',v_page.slug,'brand_key',v_page.brand_key,
      'services',v_services,'slots',v_slots
    );
  end if;

  if v_action='CREATE_HOLD' then
    if v_round.closed_at is not null or v_round.expires_at<=now() then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_NOT_AVAILABLE';
    end if;
    if v_active.appointment_id is not null then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_ALREADY_USED';
    end if;
    if v_active.checkout_hold_id is not null then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_IN_PROGRESS';
    end if;

    begin
      v_slot_id := (p_payload->>'slot_id')::uuid;
      v_service_id := (p_payload->>'service_id')::uuid;
      v_extras := coalesce(p_payload->'extra_selections','[]'::jsonb);
      v_people_count := coalesce((p_payload->>'people_count')::integer,1);
    exception when others then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ROUND_INPUT_INVALID';
    end;
    if v_people_count<1 then raise exception using errcode='P0001',message='INVALID_PEOPLE_COUNT'; end if;

    if not exists(
      select 1 from public.waitlist_private_round_slots rs
      join public.waitlist_private_slots s on s.id=rs.slot_id
      where rs.round_id=v_round.id and rs.slot_id=v_slot_id and s.status='OPEN'
    ) then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_TAKEN';
    end if;

    select i.* into v_underlying_invite
    from public.waitlist_private_invites i
    join public.waitlist_private_round_slots rs on rs.slot_id=i.slot_id
    where rs.round_id=v_round.id
      and i.slot_id=v_slot_id
      and i.waitlist_entry_id=v_round_invite.waitlist_entry_id
    for update of i;
    if not found then
      raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_NOT_FOUND';
    end if;

    v_raw_slot_token := encode(gen_random_bytes(32),'hex');
    update public.waitlist_private_invites
    set token_hash=encode(digest(v_raw_slot_token,'sha256'),'hex'),
        expires_at=least(v_round_invite.expires_at,v_round.expires_at),
        revoked_at=null,updated_at=now()
    where id=v_underlying_invite.id;

    v_hold := public.public_create_waitlist_private_checkout_hold(
      v_raw_slot_token,v_service_id,v_extras,v_people_count
    );

    update public.checkout_holds
    set attribution_json=coalesce(attribution_json,'{}'::jsonb) || jsonb_build_object(
      'private_round_id',v_round.id,'private_round_invite_id',v_round_invite.id
    )
    where id=(v_hold->>'checkout_hold_id')::uuid;

    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values(
      'WAITLIST_PRIVATE_ROUND',v_round.id,'WAITLIST_PRIVATE_ROUND_SLOT_CLAIMED',
      jsonb_build_object('round_invite_id',v_round_invite.id,'slot_id',v_slot_id,'checkout_hold_id',v_hold->>'checkout_hold_id'),
      'PUBLIC'
    );

    return v_hold || jsonb_build_object('round_id',v_round.id,'round_invite_id',v_round_invite.id,'selected_slot_id',v_slot_id);
  end if;

  raise exception using errcode='P0001',message='WAITLIST_PRIVATE_ACTION_INVALID';
end;
$function$;

revoke all on function public.service_admin_waitlist_private_round_action(text,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.public_waitlist_private_round_action(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.service_admin_waitlist_private_round_action(text,jsonb,uuid) to service_role;
grant execute on function public.public_waitlist_private_round_action(text,text,jsonb) to service_role;
