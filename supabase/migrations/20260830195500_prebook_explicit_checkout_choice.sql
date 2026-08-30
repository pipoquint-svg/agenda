-- Pré-reserva é um benefício opcional. Elegibilidade nunca deve forçar o cliente
-- a pré-reservar: PAY_NOW permanece disponível mesmo com pré-reservas ativas.

alter function public.promote_checkout_hold(
  uuid,uuid,text,uuid[],jsonb,jsonb,inet,text
) rename to promote_checkout_hold_prebook;

-- Compatibilidade defensiva: chamadas legadas sem escolha explícita seguem o
-- checkout normal. Apenas service_submit_public_checkout_choice(..., PREBOOK,...)
-- pode entrar no caminho de pré-reserva.
create function public.promote_checkout_hold(
  p_checkout_hold_id uuid,
  p_customer_id uuid,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_participants jsonb default '[]'::jsonb,
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_acceptance_user_agent text default null
)
returns jsonb
language plpgsql
set search_path to 'public','extensions'
as $$
begin
  return public.promote_checkout_hold_standard(
    p_checkout_hold_id,
    p_customer_id,
    p_coupon_code,
    p_term_version_ids,
    p_participants,
    p_answers,
    p_acceptance_ip,
    p_acceptance_user_agent
  ) || jsonb_build_object('pre_reservation', false);
end;
$$;

create or replace function public.service_public_get_checkout_prebook_option(
  p_checkout_hold_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_global_minutes integer := 2880;
  v_active_count integer := 0;
  v_authorized boolean := false;
  v_eligible boolean := false;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  select prebook_hold_minutes into v_global_minutes
  from public.operation_settings where id=1;
  if coalesce(v_global_minutes,0) <= 0 then
    raise exception using errcode='P0001',message='PREBOOK_GLOBAL_HOLD_INVALID';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = v_hold.primary_customer_id
    and is_active = true;

  if found then
    select exists(
      select 1
      from public.customer_prebook_authorized_services cas
      where cas.customer_id = v_hold.primary_customer_id
        and cas.service_id = v_hold.service_id
    ) into v_authorized;

    v_eligible := coalesce(v_terms.can_prebook,false)
      and v_terms.billing_mode = 'CHECKOUT'
      and v_authorized;
  end if;

  if v_eligible then
    perform public.service_expire_pre_reservations();
    select count(*)::integer into v_active_count
    from public.pre_reservations pr
    where pr.customer_id = v_hold.primary_customer_id
      and pr.status = 'ACTIVE'
      and pr.expires_at > now();
  end if;

  return jsonb_build_object(
    'eligible', v_eligible,
    'available', v_eligible and v_active_count < coalesce(v_terms.max_active_prebooks,0),
    'active_count', v_active_count,
    'max_active_prebooks', case when v_eligible then v_terms.max_active_prebooks else 0 end,
    'hold_minutes', v_global_minutes,
    'reason', case
      when not found then 'PREBOOK_NOT_ENABLED'
      when not coalesce(v_terms.can_prebook,false) then 'PREBOOK_NOT_ENABLED'
      when v_terms.billing_mode <> 'CHECKOUT' then 'PREBOOK_NOT_AVAILABLE'
      when not v_authorized then 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK'
      when v_active_count >= coalesce(v_terms.max_active_prebooks,0) then 'MAX_ACTIVE_PREBOOKS_REACHED'
      else null
    end
  );
end;
$$;

create or replace function public.service_submit_public_checkout_choice(
  p_checkout_hold_token text,
  p_checkout_mode text,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_mode text := upper(coalesce(nullif(btrim(p_checkout_mode),''),'PAY_NOW'));
  v_option jsonb;
begin
  if v_mode not in ('PAY_NOW','PREBOOK') then
    raise exception using errcode='P0001',message='CHECKOUT_MODE_INVALID';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;

  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  perform public.validate_checkout_answers(v_hold.service_id,coalesce(p_answers,'[]'::jsonb));

  if v_mode = 'PREBOOK' then
    v_option := public.service_public_get_checkout_prebook_option(p_checkout_hold_token);
    if not coalesce((v_option->>'eligible')::boolean,false) then
      raise exception using errcode='P0001',message='PREBOOK_NOT_AVAILABLE';
    end if;
    if not coalesce((v_option->>'available')::boolean,false) then
      raise exception using errcode='P0001',message='MAX_ACTIVE_PREBOOKS_REACHED';
    end if;

    return public.promote_checkout_hold_prebook(
      v_hold.id,
      v_hold.primary_customer_id,
      nullif(btrim(p_coupon_code),''),
      coalesce(p_term_version_ids,'{}'::uuid[]),
      '[]'::jsonb,
      coalesce(p_answers,'[]'::jsonb),
      p_acceptance_ip,
      nullif(left(p_user_agent,500),'')
    );
  end if;

  return public.promote_checkout_hold_standard(
    v_hold.id,
    v_hold.primary_customer_id,
    nullif(btrim(p_coupon_code),''),
    coalesce(p_term_version_ids,'{}'::uuid[]),
    '[]'::jsonb,
    coalesce(p_answers,'[]'::jsonb),
    p_acceptance_ip,
    nullif(left(p_user_agent,500),'')
  ) || jsonb_build_object('pre_reservation', false);
end;
$$;

-- Os dois contratos públicos legados passam a ser PAY_NOW por padrão.
create or replace function public.service_submit_public_checkout(
  p_checkout_hold_token text,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_hold public.checkout_holds%rowtype;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;
  perform public.validate_checkout_answers(v_hold.service_id,coalesce(p_answers,'[]'::jsonb));
  return public.promote_checkout_hold_standard(
    v_hold.id,v_hold.primary_customer_id,nullif(btrim(p_coupon_code),''),
    coalesce(p_term_version_ids,'{}'::uuid[]),'[]'::jsonb,coalesce(p_answers,'[]'::jsonb),
    p_acceptance_ip,nullif(left(p_user_agent,500),'')
  ) || jsonb_build_object('pre_reservation', false);
end;
$$;

create or replace function public.public_promote_checkout_hold(
  p_checkout_hold_token text,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_answers jsonb default '[]'::jsonb,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_hold public.checkout_holds%rowtype;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;
  return public.promote_checkout_hold_standard(
    v_hold.id,v_hold.primary_customer_id,nullif(btrim(p_coupon_code),''),
    coalesce(p_term_version_ids,'{}'::uuid[]),'[]'::jsonb,coalesce(p_answers,'[]'::jsonb),
    null,nullif(left(p_user_agent,500),'')
  ) || jsonb_build_object('pre_reservation', false);
end;
$$;

revoke all on function public.promote_checkout_hold_prebook(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) from public,anon,authenticated;
revoke all on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) from public,anon,authenticated;
revoke all on function public.service_public_get_checkout_prebook_option(text) from public,anon,authenticated;
revoke all on function public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text) from public,anon,authenticated;

grant execute on function public.promote_checkout_hold_prebook(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) to service_role;
grant execute on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) to service_role;
grant execute on function public.service_public_get_checkout_prebook_option(text) to service_role;
grant execute on function public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text) to service_role;

comment on function public.service_submit_public_checkout_choice(text,text,text,uuid[],jsonb,inet,text) is
  'Checkout público com escolha explícita PAY_NOW ou PREBOOK. PAY_NOW nunca é bloqueado pelo limite de pré-reservas.';
