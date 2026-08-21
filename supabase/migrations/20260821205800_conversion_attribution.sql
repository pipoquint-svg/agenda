-- Conversion attribution is first-party context attached to the booking transaction.
-- It intentionally excludes customer PII. Third-party tags remain consent-gated in the web app.

alter table public.checkout_holds
  add column attribution_json jsonb not null default '{}'::jsonb;

alter table public.appointments
  add column attribution_json jsonb not null default '{}'::jsonb;

alter table public.checkout_holds
  add constraint checkout_holds_attribution_object_check
  check (jsonb_typeof(attribution_json) = 'object');

alter table public.appointments
  add constraint appointments_attribution_object_check
  check (jsonb_typeof(attribution_json) = 'object');

create index appointments_attribution_campaign_idx
  on public.appointments ((attribution_json->>'utm_campaign'))
  where attribution_json ? 'utm_campaign';

create index appointments_attribution_source_idx
  on public.appointments ((attribution_json->>'utm_source'))
  where attribution_json ? 'utm_source';

create or replace function public.sanitize_public_attribution(p_value jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
select jsonb_strip_nulls(jsonb_build_object(
  'visitor_id', case when coalesce(p_value->>'visitor_id','') ~ '^[0-9a-fA-F-]{36}$' then left(p_value->>'visitor_id', 36) end,
  'session_id', case when coalesce(p_value->>'session_id','') ~ '^[0-9a-fA-F-]{36}$' then left(p_value->>'session_id', 36) end,
  'landing_path', nullif(left(btrim(coalesce(p_value->>'landing_path','')), 500), ''),
  'referrer', nullif(left(btrim(coalesce(p_value->>'referrer','')), 500), ''),
  'utm_source', nullif(left(btrim(coalesce(p_value->>'utm_source','')), 180), ''),
  'utm_medium', nullif(left(btrim(coalesce(p_value->>'utm_medium','')), 180), ''),
  'utm_campaign', nullif(left(btrim(coalesce(p_value->>'utm_campaign','')), 180), ''),
  'utm_content', nullif(left(btrim(coalesce(p_value->>'utm_content','')), 180), ''),
  'utm_term', nullif(left(btrim(coalesce(p_value->>'utm_term','')), 180), ''),
  'fbclid', nullif(left(btrim(coalesce(p_value->>'fbclid','')), 300), ''),
  'gclid', nullif(left(btrim(coalesce(p_value->>'gclid','')), 300), '')
));
$$;

revoke all on function public.sanitize_public_attribution(jsonb) from public, anon, authenticated;
grant execute on function public.sanitize_public_attribution(jsonb) to service_role;

create or replace function public.public_create_checkout_hold_tracked(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json) <> 'object' then
    raise exception using errcode = 'P0001', message = 'ATTRIBUTION_INVALID';
  end if;

  v_result := public.public_create_checkout_hold(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set attribution_json = public.sanitize_public_attribution(coalesce(p_attribution_json, '{}'::jsonb)),
      updated_at = now()
  where id = v_hold_id;

  return v_result;
end;
$$;

revoke all on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)
  from public;
grant execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)
  to anon, authenticated;

create or replace function public.copy_checkout_attribution_to_appointment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'PROMOTED'
     and new.promoted_appointment_id is not null
     and (old.status is distinct from new.status or old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set attribution_json = coalesce(new.attribution_json, '{}'::jsonb),
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;
  return new;
end;
$$;

create trigger checkout_hold_copy_attribution_trg
after update of status, promoted_appointment_id on public.checkout_holds
for each row execute function public.copy_checkout_attribution_to_appointment();

comment on column public.checkout_holds.attribution_json is
  'Consent-gated first-party acquisition context. PII is not accepted by the public sanitizer.';
comment on column public.appointments.attribution_json is
  'Immutable-at-promotion acquisition snapshot inherited from the checkout hold for conversion reporting.';
comment on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) is
  'Public hold creator that preserves a strict allowlist of consented acquisition parameters alongside the authoritative hold.';
