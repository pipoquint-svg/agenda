create or replace function public.service_issue_appointment_action_token(
  p_appointment_id uuid,
  p_scope text,
  p_channel text,
  p_destination_masked text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_start_at timestamptz;
  v_token_id uuid;
  v_cancel_token_id uuid;
  v_raw_token text;
  v_cancel_raw_token text;
  v_hash text;
  v_cancel_hash text;
  v_expires_at timestamptz;
  v_request_id text:=nullif(left(coalesce(p_request_id,''),200),'');
  v_confirmation_manage_link boolean:=false;
begin
  if p_scope not in ('CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS') then
    raise exception using errcode='22023',message='ACTION_TOKEN_SCOPE_INVALID';
  end if;
  if p_channel not in ('WHATSAPP','EMAIL','BOTH','INTERNAL') then
    raise exception using errcode='22023',message='TOKEN_EVENT_CHANNEL_INVALID';
  end if;
  if nullif(btrim(coalesce(p_destination_masked,'')),'') is null then
    raise exception using errcode='22023',message='TOKEN_DESTINATION_MASK_REQUIRED';
  end if;

  select start_at into v_start_at from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_start_at<=now() then raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_EXPIRED'; end if;
  v_expires_at:=v_start_at;

  v_confirmation_manage_link := p_scope='RESCHEDULE'
    and p_channel='EMAIL'
    and coalesce(p_request_id,'') like 'confirmation-email:%';

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  insert into public.appointment_access_tokens(
    appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,issued_request_id
  ) values(
    p_appointment_id,v_hash,p_scope,v_expires_at,p_channel,left(btrim(p_destination_masked),160),v_request_id
  ) returning id into v_token_id;

  perform public.service_record_appointment_token_event(
    v_token_id,'ISSUED',p_channel,p_destination_masked,null,null,p_request_id,
    jsonb_build_object('scope',p_scope,'expires_at',v_expires_at)
  );

  if v_confirmation_manage_link then
    v_cancel_raw_token:=encode(gen_random_bytes(32),'hex');
    v_cancel_hash:=encode(digest(v_cancel_raw_token,'sha256'),'hex');
    insert into public.appointment_access_tokens(
      appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,issued_request_id
    ) values(
      p_appointment_id,v_cancel_hash,'CANCEL',v_expires_at,p_channel,left(btrim(p_destination_masked),160),v_request_id
    ) returning id into v_cancel_token_id;

    perform public.service_record_appointment_token_event(
      v_cancel_token_id,'ISSUED',p_channel,p_destination_masked,null,null,p_request_id,
      jsonb_build_object('scope','CANCEL','expires_at',v_expires_at,'paired_token_id',v_token_id)
    );

    return jsonb_build_object(
      'token_id',v_token_id,
      'cancel_token_id',v_cancel_token_id,
      'access_token','m1.'||v_raw_token||'.'||v_cancel_raw_token,
      'scope',p_scope,
      'expires_at',v_expires_at,
      'composite',true
    );
  end if;

  return jsonb_build_object(
    'token_id',v_token_id,
    'access_token',v_raw_token,
    'scope',p_scope,
    'expires_at',v_expires_at
  );
end;
$function$;

create or replace function public.service_record_appointment_token_delivery(
  p_token_id uuid,
  p_channel text,
  p_destination_masked text,
  p_request_id text default null,
  p_provider_message_id text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid;
  v_primary public.appointment_access_tokens%rowtype;
  v_pair_id uuid;
begin
  v_event_id:=public.service_record_appointment_token_event(
    p_token_id,'DELIVERY_RECORDED',p_channel,p_destination_masked,null,null,p_request_id,
    jsonb_strip_nulls(jsonb_build_object('provider_message_id',nullif(left(coalesce(p_provider_message_id,''),200),'')))
  );

  select * into v_primary from public.appointment_access_tokens where id=p_token_id;
  if found and v_primary.scope='RESCHEDULE' and coalesce(v_primary.issued_request_id,'') like 'confirmation-email:%' then
    select id into v_pair_id
    from public.appointment_access_tokens
    where appointment_id=v_primary.appointment_id
      and scope='CANCEL'
      and issued_request_id=v_primary.issued_request_id
      and expires_at=v_primary.expires_at
      and id<>v_primary.id
    order by created_at desc
    limit 1;

    if v_pair_id is not null then
      perform public.service_record_appointment_token_event(
        v_pair_id,'DELIVERY_RECORDED',p_channel,p_destination_masked,null,null,p_request_id,
        jsonb_strip_nulls(jsonb_build_object(
          'provider_message_id',nullif(left(coalesce(p_provider_message_id,''),200),''),
          'paired_token_id',p_token_id
        ))
      );
    end if;
  end if;

  return v_event_id;
end;
$function$;
