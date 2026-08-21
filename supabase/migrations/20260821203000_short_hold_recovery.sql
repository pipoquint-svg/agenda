alter table public.checkout_holds
  add column recovery_public_token text not null default encode(gen_random_bytes(24), 'hex'),
  add column recovery_phone text,
  add column recovery_enabled boolean not null default false,
  add column recovery_token_expires_at timestamptz not null default (now() + interval '7 days'),
  add column recovery_enqueued_at timestamptz;

create unique index checkout_holds_recovery_public_token_uq
  on public.checkout_holds (recovery_public_token);

create table public.message_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique,
  channel text not null check (channel in ('WHATSAPP','EMAIL')),
  provider_template_name text not null,
  language_code text not null default 'pt_BR',
  body_preview text not null,
  parameter_schema jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.message_templates (
  template_key,
  channel,
  provider_template_name,
  language_code,
  body_preview,
  parameter_schema
) values (
  'checkout_hold_expired_recovery',
  'WHATSAPP',
  'checkout_hold_expired_recovery',
  'pt_BR',
  'Seu horário não ficou reservado. Você pode retomar sua escolha por aqui: {{1}}',
  '[{"position":1,"name":"resume_url","type":"text"}]'::jsonb
)
on conflict (template_key) do nothing;

create or replace function public.set_checkout_hold_recovery_contact(
  p_checkout_hold_token text,
  p_phone text,
  p_enabled boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_phone text;
begin
  if p_checkout_hold_token is null or btrim(p_checkout_hold_token) = '' then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  if p_enabled and length(v_phone) not between 10 and 15 then
    raise exception using errcode = 'P0001', message = 'RECOVERY_PHONE_INVALID';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  if v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  update public.checkout_holds
  set recovery_phone = case when p_enabled then v_phone else null end,
      recovery_enabled = p_enabled,
      updated_at = now()
  where id = v_hold.id;

  return jsonb_build_object(
    'checkout_hold_id', v_hold.id,
    'recovery_enabled', p_enabled
  );
end;
$$;

revoke all on function public.set_checkout_hold_recovery_contact(text, text, boolean) from public;
grant execute on function public.set_checkout_hold_recovery_contact(text, text, boolean) to anon, authenticated, service_role;

create or replace function public.get_checkout_hold_resume_context(
  p_recovery_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_timezone text;
  v_original_slot_available boolean := false;
begin
  if p_recovery_token is null or btrim(p_recovery_token) = '' then
    raise exception using errcode = 'P0001', message = 'RECOVERY_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where recovery_public_token = p_recovery_token;

  if not found
     or v_hold.status <> 'EXPIRED'
     or v_hold.recovery_token_expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'RECOVERY_TOKEN_INVALID_OR_EXPIRED';
  end if;

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  select exists (
    select 1
    from public.list_available_slots(
      v_hold.service_id,
      v_hold.service_employee_id,
      v_hold.extra_selections,
      v_hold.people_count,
      (v_hold.requested_start_at at time zone v_timezone)::date,
      null
    ) slot
    where slot.slot_start_at = v_hold.requested_start_at
  ) into v_original_slot_available;

  return jsonb_build_object(
    'service_id', v_hold.service_id,
    'service_employee_id', v_hold.service_employee_id,
    'extra_selections', v_hold.extra_selections,
    'people_count', v_hold.people_count,
    'original_start_at', v_hold.requested_start_at,
    'original_slot_available', v_original_slot_available,
    'hold_status', v_hold.status
  );
end;
$$;

revoke all on function public.get_checkout_hold_resume_context(text) from public;
grant execute on function public.get_checkout_hold_resume_context(text) to anon, authenticated, service_role;

create or replace function public.expire_due_checkout_holds()
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_hold public.checkout_holds%rowtype;
begin
  for v_hold in
    select ch.*
    from public.checkout_holds ch
    where ch.status = 'ACTIVE'
      and ch.expires_at <= now()
    for update skip locked
  loop
    update public.checkout_holds
    set status = 'EXPIRED', updated_at = now()
    where id = v_hold.id;

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';

    update public.checkout_hour_package_reservations
    set status = 'RELEASED',
        released_at = now(),
        release_reason = 'CHECKOUT_HOLD_EXPIRED',
        updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';

    if v_hold.recovery_enabled
       and v_hold.recovery_phone is not null
       and v_hold.recovery_token_expires_at > now()
       and v_hold.recovery_enqueued_at is null then
      insert into public.integration_jobs (
        job_type,
        entity_type,
        entity_id,
        payload_json,
        idempotency_key
      ) values (
        'CHECKOUT_HOLD_EXPIRED_RECOVERY',
        'CHECKOUT_HOLD',
        v_hold.id,
        jsonb_build_object(
          'template_key', 'checkout_hold_expired_recovery',
          'phone', v_hold.recovery_phone,
          'resume_token', v_hold.recovery_public_token
        ),
        'checkout-hold-expired-recovery:' || v_hold.id::text
      )
      on conflict (idempotency_key) do nothing;

      update public.checkout_holds
      set recovery_enqueued_at = now(), updated_at = now()
      where id = v_hold.id;
    end if;
  end loop;
end;
$$;

comment on function public.create_checkout_hold(uuid, uuid, jsonb, integer, timestamptz) is
  'Public booking contract: call immediately after the user selects a time. The hold protects all required resources while the remaining checkout form is completed.';

comment on function public.get_checkout_hold_resume_context(text) is
  'Returns only sanitized commercial selection context. A recovery token never revives or reserves the expired slot.';
