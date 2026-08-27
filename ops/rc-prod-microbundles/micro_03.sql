
-- BEGIN RC MIGRATION 20260823095000_action_token_public_summary.sql
-- Safe public summary for tokenized appointment actions.
-- The summary deliberately excludes customer/contact/payment details and is only
-- callable by the server-side service role after the action token was resolved.

create or replace function public.service_appointment_action_public_summary(
  p_token_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_resource_name text;
  v_status_label text;
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id;

  if not found
     or v_token.scope not in ('CANCEL','RESCHEDULE')
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_token.appointment_id
    and deleted_at is null;

  if not found
     or v_appointment.start_at <= now()
     or v_token.expires_at <> v_appointment.start_at then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_resource_name := case
    when v_service.operation_scope = 'BLACKSHEEP' then 'BlackSheep Estúdio Criativo'
    else null
  end;

  v_status_label := case v_appointment.status::text
    when 'CONFIRMED' then 'Confirmada'
    when 'AWAITING_PAYMENT' then 'Aguardando pagamento'
    when 'CANCELLED' then 'Cancelada'
    when 'COMPLETED' then 'Concluída'
    when 'NO_SHOW' then 'Não compareceu'
    else 'Em andamento'
  end;

  return jsonb_strip_nulls(jsonb_build_object(
    'public_code', v_appointment.public_code,
    'service_name', coalesce(v_appointment.service_name_snapshot, v_service.name),
    'resource_name', v_resource_name,
    'operation_scope', v_service.operation_scope,
    'start_at', v_appointment.start_at,
    'end_at', v_appointment.end_at,
    'status_label', v_status_label
  ));
end;
$$;

revoke all on function public.service_appointment_action_public_summary(uuid)
from public, anon, authenticated;
grant execute on function public.service_appointment_action_public_summary(uuid) to service_role;

comment on function public.service_appointment_action_public_summary(uuid) is
  'Returns the minimal non-PII appointment summary needed by the tokenized cancel/reschedule UI. Requires a currently valid CANCEL or RESCHEDULE token id and exposes no customer/contact/payment data.';
-- END RC MIGRATION 20260823095000_action_token_public_summary.sql

-- BEGIN RC MIGRATION 20260823096000_revoke_authorship_trigger_execute.sql
-- Trigger-only function: PostgreSQL triggers execute it as the function owner.
-- It is not part of the public/admin RPC surface and must never be callable
-- directly through PostgREST by anon, authenticated or service_role.

revoke execute on function public.reject_appointment_authorship_mutation()
from public, anon, authenticated, service_role;

comment on function public.reject_appointment_authorship_mutation() is
  'Internal trigger-only append-only guard. Direct EXECUTE is intentionally revoked from API roles.';
-- END RC MIGRATION 20260823096000_revoke_authorship_trigger_execute.sql

-- BEGIN RC MIGRATION 20260823165000_kommo_blacksheep_pipeline_mapping.sql
alter table public.kommo_integration_settings
  add column if not exists stage_initial_contact_id bigint;

alter table public.kommo_integration_settings
  drop constraint if exists kommo_integration_settings_stage_initial_contact_id_check;

alter table public.kommo_integration_settings
  add constraint kommo_integration_settings_stage_initial_contact_id_check
  check (stage_initial_contact_id is null or stage_initial_contact_id > 0);

update public.kommo_integration_settings
set account_subdomain = 'pierriquintproducoes',
    pipeline_id = 11507124,
    stage_initial_contact_id = 88360028,
    stage_awaiting_payment_id = 88360032,
    stage_confirmed_id = 88360036,
    stage_rescheduled_id = 95038752,
    stage_completed_id = 95038756,
    stage_cancelled_id = 96091804,
    stage_no_show_id = 96091808,
    stage_expired_id = 110702983,
    updated_at = now()
where id = 1;

comment on column public.kommo_integration_settings.stage_initial_contact_id is
  'BlackSheep pre-booking CRM stage. Customer identity is resolved globally in Kommo Contacts by exact normalized phone. This stage is used only to optionally reuse one unclaimed pre-booking lead; one contact may have multiple reservation leads.';
-- END RC MIGRATION 20260823165000_kommo_blacksheep_pipeline_mapping.sql

-- BEGIN RC MIGRATION 20260823172000_kommo_card_projection.sql
-- Kommo card projection for BlackSheep reservations.
-- Agenda remains authoritative. Kommo mirrors operational/card data only.
-- Shared Kommo lead card semantics:
--   Data            <- appointment.start_at (America/Sao_Paulo in Edge adapter)
--   Venda           <- appointment.commercial_value (Kommo built-in lead price)
--   Saldo           <- get_appointment_financial_summary().contract_balance
--   Extras locação  <- appointment_extras snapshots

create or replace function public.get_kommo_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_settings public.kommo_integration_settings%rowtype;
  v_stage_key text;
  v_financial jsonb;
  v_extras jsonb;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  select * into v_settings
  from public.kommo_integration_settings
  where id = 1;

  if not found or not v_settings.enabled or v_service.operation_scope is distinct from 'BLACKSHEEP' then
    return jsonb_build_object(
      'appointment_id', v_appointment.id,
      'version', v_appointment.version,
      'eligible', false,
      'reason', case
        when v_service.operation_scope is distinct from 'BLACKSHEEP' then 'OPERATION_SCOPE_NOT_BLACKSHEEP'
        else 'KOMMO_DISABLED'
      end
    );
  end if;

  if v_appointment.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_appointment.primary_customer_id;
  end if;

  v_stage_key := case v_appointment.status
    when 'AWAITING_PAYMENT' then 'AWAITING_PAYMENT'
    when 'CONFIRMED' then 'CONFIRMED'
    when 'COMPLETED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
    when 'NO_SHOW' then 'NO_SHOW'
    when 'EXPIRED' then 'EXPIRED'
    else 'CREATED'
  end;

  v_financial := public.get_appointment_financial_summary(v_appointment.id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', ae.id,
        'extra_id', ae.extra_id,
        'name', ae.name_snapshot,
        'quantity', ae.quantity,
        'unit_price', ae.unit_price_snapshot,
        'total_price', ae.total_price
      ) order by ae.created_at, ae.id
    ),
    '[]'::jsonb
  ) into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = v_appointment.id;

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'version', v_appointment.version,
    'eligible', true,
    'operation_scope', v_service.operation_scope,
    'appointment_status', v_appointment.status,
    'financial_status', v_appointment.financial_status,
    'stage_key', v_stage_key,
    'service', jsonb_build_object(
      'id', v_service.id,
      'name', coalesce(nullif(v_appointment.service_name_snapshot, ''), v_service.name)
    ),
    'schedule', jsonb_build_object(
      'start_at', v_appointment.start_at,
      'end_at', v_appointment.end_at
    ),
    'commercial_value', v_appointment.commercial_value,
    'financial', v_financial,
    'extras', v_extras,
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone
    ) end
  );
end;
$$;

revoke all on function public.get_kommo_appointment_desired_state(uuid) from public, anon, authenticated;
grant execute on function public.get_kommo_appointment_desired_state(uuid) to service_role;

-- Appointment version is intentionally not the sole idempotency dimension. Financial
-- coverage and extras can change while the appointment version remains unchanged.
-- Fingerprinting the canonical projection lets those same-version changes enqueue safely.
create or replace function public.enqueue_kommo_appointment_sync(
  p_appointment_id uuid,
  p_event_kind text default 'UPDATED'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_enabled boolean;
  v_job_id uuid;
  v_event text := upper(btrim(coalesce(p_event_kind, 'UPDATED')));
  v_projection jsonb;
  v_fingerprint text;
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED','EXTRAS_CHANGED') then
    raise exception using errcode = 'P0001', message = 'KOMMO_EVENT_KIND_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select operation_scope into v_scope
  from public.services
  where id = v_appointment.service_id;

  select enabled into v_enabled
  from public.kommo_integration_settings
  where id = 1;

  if not coalesce(v_enabled, false) or v_scope is distinct from 'BLACKSHEEP' then
    return null;
  end if;

  v_projection := public.get_kommo_appointment_desired_state(v_appointment.id);
  if coalesce((v_projection->>'eligible')::boolean, false) is not true then
    return null;
  end if;

  v_fingerprint := md5(v_projection::text || ':' || v_event);

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'KOMMO_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_appointment.version,
    jsonb_build_object('event_kind', v_event, 'projection_fingerprint', v_fingerprint),
    'PENDING',
    now(),
    'kommo-appointment:' || v_appointment.id::text || ':v' || v_appointment.version::text || ':' || lower(v_event) || ':' || v_fingerprint
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_kommo_appointment_sync(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_kommo_appointment_sync(uuid,text) to service_role;

-- Payment rows can change Saldo without changing appointment.version. Mirror every
-- authoritative contract-payment mutation through the same outbox function.
create or replace function public.trg_enqueue_kommo_payment_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'FINANCIAL_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_payment_sync() from public, anon, authenticated, service_role;

drop trigger if exists payment_transactions_enqueue_kommo_sync on public.payment_transactions;
create trigger payment_transactions_enqueue_kommo_sync
after insert or delete or update of status, contract_amount_settled, payment_discount_amount, cash_amount, transaction_type, payment_purpose, parent_transaction_id
on public.payment_transactions
for each row execute function public.trg_enqueue_kommo_payment_sync();

-- Extras are appointment-owned snapshots. Any add/edit/remove must update the existing
-- lead card rather than create a new lead.
create or replace function public.trg_enqueue_kommo_extra_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'EXTRAS_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_extra_sync() from public, anon, authenticated, service_role;

drop trigger if exists appointment_extras_enqueue_kommo_sync on public.appointment_extras;
create trigger appointment_extras_enqueue_kommo_sync
after insert or delete or update of extra_id, name_snapshot, unit_price_snapshot, quantity, total_price
on public.appointment_extras
for each row execute function public.trg_enqueue_kommo_extra_sync();

comment on function public.get_kommo_appointment_desired_state(uuid) is
  'Canonical Agenda-to-Kommo projection including reservation date, authoritative finance balance and contracted extras. Agenda remains authoritative.';
comment on function public.enqueue_kommo_appointment_sync(uuid,text) is
  'Idempotent Kommo outbox enqueue keyed by canonical projection fingerprint so same-version finance/extra changes are mirrored safely.';
comment on function public.trg_enqueue_kommo_payment_sync() is
  'Internal trigger only: refresh Kommo Saldo after payment/refund mutations.';
comment on function public.trg_enqueue_kommo_extra_sync() is
  'Internal trigger only: refresh Kommo Extras locação after appointment-extra mutations.';
-- END RC MIGRATION 20260823172000_kommo_card_projection.sql

-- BEGIN RC MIGRATION 20260823204500_integration_production_security_hardening.sql
-- Production hardening discovered during the integration audit on 2026-08-23.
-- Direct browser/database access is deny-by-default. Public booking reads remain exposed
-- only through the intentionally public SECURITY DEFINER RPC contracts.

revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;

-- Preserve the five intentional public booking RPCs. Their definitions already pin
-- search_path=public and untrusted roles cannot CREATE in public, preventing object shadowing.
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
grant execute on function public.public_list_available_slots(text, uuid, uuid, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_list_available_slots_duration(text, uuid, uuid, integer, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_quote_booking(text, uuid, uuid, jsonb, integer) to anon, authenticated;
grant execute on function public.public_quote_booking_duration(text, uuid, uuid, integer, jsonb, integer) to anon, authenticated;

-- Future objects must be granted deliberately instead of inheriting broad browser rights.
alter default privileges in schema public revoke all privileges on tables from anon, authenticated;
alter default privileges in schema public revoke all privileges on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- Cover foreign keys reported by the Supabase performance advisor. These are additive
-- indexes only; no existing integrity/uniqueness index is removed.
create index if not exists admin_user_permissions_updated_by_idx
  on public.admin_user_permissions(updated_by_admin_id);
create index if not exists authorship_events_admin_user_idx
  on public.appointment_authorship_events(admin_user_id);
create index if not exists authorship_events_access_token_idx
  on public.appointment_authorship_events(appointment_access_token_id);
create index if not exists final_settlements_admin_user_idx
  on public.appointment_final_settlements(admin_user_id);
create index if not exists policy_actions_refund_tx_idx
  on public.appointment_policy_actions(refund_transaction_id);
create index if not exists booking_page_services_service_idx
  on public.booking_page_services(service_id);
create index if not exists coupon_services_service_idx
  on public.coupon_services(service_id);
create index if not exists coupons_customer_idx
  on public.coupons(customer_id);
create index if not exists coupons_source_appointment_idx
  on public.coupons(source_appointment_id);
create index if not exists balance_movements_admin_user_idx
  on public.customer_balance_movements(admin_user_id);
create index if not exists balance_refund_requests_admin_idx
  on public.customer_balance_refund_requests(admin_user_id);
create index if not exists prebook_authorized_services_service_idx
  on public.customer_prebook_authorized_services(service_id);
create index if not exists extra_resources_resource_idx
  on public.extra_resources(resource_id);
create index if not exists google_calendar_resources_resource_idx
  on public.google_calendar_resources(resource_id);
create index if not exists google_oauth_states_admin_idx
  on public.google_oauth_states(requested_by_admin_user_id);
create index if not exists google_watch_channels_calendar_idx
  on public.google_watch_channels(google_calendar_id);
create index if not exists hour_package_services_service_idx
  on public.hour_package_services(service_id);
create index if not exists legacy_amelia_first_batch_idx
  on public.legacy_amelia_bookings(first_import_batch_id);
create index if not exists legacy_amelia_last_batch_idx
  on public.legacy_amelia_bookings(last_import_batch_id);
create index if not exists legacy_amelia_matched_customer_idx
  on public.legacy_amelia_bookings(matched_customer_id);
create index if not exists legacy_amelia_batches_admin_idx
  on public.legacy_amelia_import_batches(created_by_admin_user_id);
create index if not exists operation_settings_occupancy_resource_idx
  on public.operation_settings(dashboard_occupancy_resource_id);
create index if not exists employee_calendar_write_calendar_idx
  on public.service_employee_calendar_write(google_calendar_id);
-- END RC MIGRATION 20260823204500_integration_production_security_hardening.sql

-- BEGIN RC MIGRATION 20260823221500_duration_guidance_ranges.sql
-- Editorial guidance for variable-duration services.
-- This table carries no pricing logic: it only helps the UI explain what can
-- typically be produced within a selected duration range.

create table if not exists public.service_duration_guidance_ranges (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  min_blocks integer not null check (min_blocks > 0),
  max_blocks integer check (max_blocks is null or max_blocks >= min_blocks),
  title text not null check (btrim(title) <> ''),
  description text not null check (btrim(description) <> ''),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_duration_guidance_ranges_service_idx
  on public.service_duration_guidance_ranges(service_id, is_active, min_blocks, max_blocks, sort_order);

alter table public.service_duration_guidance_ranges enable row level security;
revoke all on public.service_duration_guidance_ranges from public, anon, authenticated;

create or replace function public.public_get_booking_page(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'id', bp.id,
  'slug', bp.slug,
  'display_name', bp.display_name,
  'title', bp.title,
  'subtitle', bp.subtitle,
  'brand_key', bp.brand_key,
  'logo_url', bp.logo_url,
  'accent_color', bp.accent_color,
  'require_tax_id', bp.require_tax_id,
  'services', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'short_description', s.short_description,
        'cover_image_url', s.cover_image_url,
        'base_duration_minutes', s.base_duration_minutes,
        'base_price', s.base_price,
        'duration_mode', s.duration_mode,
        'booking_block_minutes', s.booking_block_minutes,
        'minimum_booking_blocks', s.minimum_booking_blocks,
        'maximum_booking_blocks', s.maximum_booking_blocks,
        'price_per_block', s.price_per_block,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'minimum_people', s.minimum_people,
        'maximum_people', s.maximum_people,
        'requires_terms', s.requires_terms,
        'duration_presets', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.id,
            'block_count', p.block_count,
            'title', p.title,
            'description', p.description,
            'badge', p.badge,
            'is_featured', p.is_featured
          ) order by p.sort_order, p.block_count, p.id)
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id,
            'min_blocks', g.min_blocks,
            'max_blocks', g.max_blocks,
            'title', g.title,
            'description', g.description
          ) order by g.sort_order, g.min_blocks, g.id)
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
        'employees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'service_employee_id', se.id,
            'employee_id', e.id,
            'name', e.name
          ) order by e.name, se.id)
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'description', e.description,
            'price', e.price,
            'duration_delta_minutes', e.duration_delta_minutes,
            'is_required', sx.is_required,
            'max_quantity', sx.max_quantity,
            'schedule_placement', sx.schedule_placement,
            'default_schedule_minutes', sx.default_schedule_minutes
          ) order by sx.sort_order, e.name, e.id)
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
        'fields', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', sf.id,
            'field_key', sf.field_key,
            'label', sf.label,
            'field_type', sf.field_type,
            'help_text', sf.help_text,
            'placeholder', sf.placeholder,
            'is_required', sf.is_required,
            'options', sf.options_json
          ) order by sf.sort_order, sf.id)
          from public.service_fields sf
          where sf.service_id = s.id and sf.is_active
        ), '[]'::jsonb)
      ) order by bps.sort_order, s.sort_order, s.name
    )
    from public.booking_page_services bps
    join public.services s on s.id = bps.service_id and s.is_active
    where bps.booking_page_id = bp.id and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug)) and bp.is_active;
$$;

revoke all on function public.public_get_booking_page(text) from public;
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
-- END RC MIGRATION 20260823221500_duration_guidance_ranges.sql

-- BEGIN RC MIGRATION 20260823235500_fix_duration_checkout_origin.sql
-- Preserve the public booking-page origin on duration-based checkout holds.
-- The FIXED wrapper already does this; BLOCKS must follow the same contract so
-- public_get_checkout_context can enforce CHECKOUT_ORIGIN_MISSING fail-closed.

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug = lower(btrim(p_booking_page_slug))
    and is_active;

  if v_page_id is null then
    raise exception using errcode = 'P0001', message = 'BOOKING_PAGE_NOT_AVAILABLE';
  end if;

  v_result := public.create_checkout_hold_for_duration(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id = v_page_id,
      updated_at = now()
  where id = v_hold_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  return v_result || jsonb_build_object(
    'booking_page_slug', lower(btrim(p_booking_page_slug))
  );
end;
$$;

-- Keep the production hardening contract: state-changing public RPCs are callable
-- only through the Edge gateway, never directly from anon/authenticated clients.
revoke all on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) from public, anon, authenticated;
grant execute on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) to service_role;
-- END RC MIGRATION 20260823235500_fix_duration_checkout_origin.sql

-- BEGIN RC MIGRATION 20260823235600_restore_duration_pricing_tiers_catalog.sql
-- Restore duration_pricing_tiers in the public catalog after the duration-guidance
-- migration replaced public_get_booking_page. Preserve the new editorial guidance too.

create or replace function public.public_get_booking_page(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'id', bp.id,
  'slug', bp.slug,
  'display_name', bp.display_name,
  'title', bp.title,
  'subtitle', bp.subtitle,
  'brand_key', bp.brand_key,
  'logo_url', bp.logo_url,
  'accent_color', bp.accent_color,
  'require_tax_id', bp.require_tax_id,
  'services', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'short_description', s.short_description,
        'cover_image_url', s.cover_image_url,
        'base_duration_minutes', s.base_duration_minutes,
        'base_price', s.base_price,
        'duration_mode', s.duration_mode,
        'booking_block_minutes', s.booking_block_minutes,
        'minimum_booking_blocks', s.minimum_booking_blocks,
        'maximum_booking_blocks', s.maximum_booking_blocks,
        'price_per_block', s.price_per_block,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'minimum_people', s.minimum_people,
        'maximum_people', s.maximum_people,
        'requires_terms', s.requires_terms,
        'duration_pricing_tiers', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'min_blocks', t.min_blocks,
            'max_blocks', t.max_blocks,
            'price_per_block', t.price_per_block
          ) order by t.sort_order, t.min_blocks, t.id)
          from public.service_duration_pricing_tiers t
          where t.service_id = s.id and t.is_active
        ), '[]'::jsonb),
        'duration_presets', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.id,
            'block_count', p.block_count,
            'title', p.title,
            'description', p.description,
            'badge', p.badge,
            'is_featured', p.is_featured
          ) order by p.sort_order, p.block_count, p.id)
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id,
            'min_blocks', g.min_blocks,
            'max_blocks', g.max_blocks,
            'title', g.title,
            'description', g.description
          ) order by g.sort_order, g.min_blocks, g.id)
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
        'employees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'service_employee_id', se.id,
            'employee_id', e.id,
            'name', e.name
          ) order by e.name, se.id)
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'description', e.description,
            'price', e.price,
            'duration_delta_minutes', e.duration_delta_minutes,
            'is_required', sx.is_required,
            'max_quantity', sx.max_quantity,
            'schedule_placement', sx.schedule_placement,
            'default_schedule_minutes', sx.default_schedule_minutes
          ) order by sx.sort_order, e.name, e.id)
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
        'fields', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', sf.id,
            'field_key', sf.field_key,
            'label', sf.label,
            'field_type', sf.field_type,
            'help_text', sf.help_text,
            'placeholder', sf.placeholder,
            'is_required', sf.is_required,
            'options', sf.options_json
          ) order by sf.sort_order, sf.id)
          from public.service_fields sf
          where sf.service_id = s.id and sf.is_active
        ), '[]'::jsonb)
      ) order by bps.sort_order, s.sort_order, s.name
    )
    from public.booking_page_services bps
    join public.services s on s.id = bps.service_id and s.is_active
    where bps.booking_page_id = bp.id and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug)) and bp.is_active;
$$;

revoke all on function public.public_get_booking_page(text) from public;
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
-- END RC MIGRATION 20260823235600_restore_duration_pricing_tiers_catalog.sql

-- BEGIN RC MIGRATION 20260824002000_payment_method_preview.sql
-- Preview autoritativo dos valores por método de pagamento.
-- A UI nunca calcula desconto: recebe o valor líquido já calculado pelo banco.

create or replace function public.service_calculate_payment_cash_amount(
  p_contract_amount numeric,
  p_method text,
  p_pix_discount_percent numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  v_contract := round(coalesce(p_contract_amount, 0), 2);
  v_discount_percent := round(coalesce(p_pix_discount_percent, 0), 2);

  if v_contract < 0 then
    raise exception using errcode = '22023', message = 'PAYMENT_AMOUNT_INVALID';
  end if;
  if v_discount_percent < 0 or v_discount_percent > 100 then
    raise exception using errcode = '22023', message = 'PIX_DISCOUNT_PERCENT_INVALID';
  end if;

  v_discount := case
    when p_method = 'PIX' then round(v_contract * v_discount_percent / 100, 2)
    else 0
  end;
  v_cash := round(v_contract - v_discount, 2);

  return jsonb_build_object(
    'contract_amount', v_contract,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash,
    'method', p_method
  );
end;
$$;

revoke all on function public.service_calculate_payment_cash_amount(numeric,text,numeric) from public, anon, authenticated;
grant execute on function public.service_calculate_payment_cash_amount(numeric,text,numeric) to service_role;

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  -- Reusa toda a validação autoritativa de token/status/hold já existente.
  v_context := public.service_get_public_payment_context(p_access_token);

  v_minimum_contract := round(coalesce((v_context->>'minimum_due_contract_amount')::numeric, 0), 2);
  v_full_contract := round(coalesce((v_context->>'contract_balance')::numeric, 0), 2);

  select round(coalesce(os.pix_discount_percent, 0), 2)
  into v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if v_discount_percent is null then
    raise exception using errcode = 'P0001', message = 'PAYMENT_SETTINGS_LOAD_FAILED';
  end if;

  v_minimum_pix := public.service_calculate_payment_cash_amount(v_minimum_contract, 'PIX', v_discount_percent);
  v_full_pix := public.service_calculate_payment_cash_amount(v_full_contract, 'PIX', v_discount_percent);

  return jsonb_build_object(
    'pix_discount_percent', v_discount_percent,
    'confirmation_percentage', (v_context->>'confirmation_percentage')::numeric,
    'minimum_available', coalesce((v_context->>'minimum_available')::boolean, false),
    'full_available', coalesce((v_context->>'full_available')::boolean, false),
    'minimum_due_contract_amount', v_minimum_contract,
    'minimum_due_card_cash_amount', v_minimum_contract,
    'minimum_due_pix_cash_amount', (v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount', v_full_contract,
    'full_due_card_cash_amount', v_full_contract,
    'full_due_pix_cash_amount', (v_full_pix->>'cash_amount')::numeric
  );
end;
$$;

revoke all on function public.service_get_public_payment_method_preview(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_method_preview(text) to service_role;

-- Mantém create_payment_intent como fonte da cobrança e faz o cálculo usar o
-- mesmo helper do preview, eliminando divergência de arredondamento/regra.
create or replace function public.create_payment_intent(
  p_appointment_id uuid,
  p_payment_percentage numeric,
  p_method text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_amounts jsonb;
  v_transaction_id uuid;
  v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_existing
  from public.payment_transactions
  where idempotency_key = p_idempotency_key;

  if found then
    if v_existing.appointment_id <> p_appointment_id
       or v_existing.method <> p_method
       or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'transaction_id', v_existing.id,
      'appointment_id', v_existing.appointment_id,
      'status', v_existing.status,
      'payment_percentage', v_existing.requested_percentage,
      'contract_amount_settled', v_existing.contract_amount_settled,
      'payment_discount_amount', v_existing.payment_discount_amount,
      'cash_amount', v_existing.cash_amount,
      'method', v_existing.method,
      'idempotent_replay', true
    );
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_PAYABLE';
  end if;

  if v_appointment.status = 'AWAITING_PAYMENT'
     and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now()) then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  select
    coalesce(v_service.confirmation_percentage, os.default_confirmation_percentage),
    os.pix_discount_percent
  into v_confirmation_percentage, v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if p_payment_percentage <> 100
     and p_payment_percentage <> v_confirmation_percentage then
    raise exception using errcode = 'P0001', message = 'INVALID_PAYMENT_PERCENTAGE';
  end if;

  v_summary := public.get_appointment_financial_summary(p_appointment_id);
  v_balance := (v_summary->>'contract_balance')::numeric;
  v_settled_before := (v_summary->>'contract_settled')::numeric;

  if v_balance <= 0 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_ALREADY_PAID';
  end if;

  v_confirmation_target := round(
    coalesce(v_appointment.commercial_value, 0) * v_confirmation_percentage / 100,
    2
  );

  if p_payment_percentage = 100 then
    v_payment_kind := 'FULL_BALANCE';
    v_contract_amount := v_balance;
  else
    v_payment_kind := 'CONFIRMATION_MINIMUM';
    v_contract_amount := round(greatest(v_confirmation_target - v_settled_before, 0), 2);

    if v_contract_amount <= 0 then
      raise exception using errcode = 'P0001', message = 'CONFIRMATION_PAYMENT_ALREADY_SATISFIED';
    end if;

    v_contract_amount := least(v_contract_amount, v_balance);
  end if;

  v_amounts := public.service_calculate_payment_cash_amount(v_contract_amount, p_method, v_discount_percent);
  v_discount := (v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount := (v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions (
    appointment_id,
    transaction_type,
    method,
    provider,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    idempotency_key,
    requested_percentage
  ) values (
    p_appointment_id,
    'CHARGE',
    p_method,
    'MERCADO_PAGO',
    'PENDING',
    v_contract_amount,
    v_discount,
    v_cash_amount,
    p_idempotency_key,
    p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments
    set financial_status = 'PENDING',
        updated_at = now()
    where id = p_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'appointment_id', p_appointment_id,
    'status', 'PENDING',
    'payment_kind', v_payment_kind,
    'payment_percentage', p_payment_percentage,
    'confirmation_percentage', v_confirmation_percentage,
    'confirmation_target_amount', v_confirmation_target,
    'contract_settled_before', v_settled_before,
    'contract_balance_before', v_balance,
    'contract_amount_settled', v_contract_amount,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash_amount,
    'method', p_method,
    'provider', 'MERCADO_PAGO',
    'idempotent_replay', false
  );
end;
$$;
-- END RC MIGRATION 20260824002000_payment_method_preview.sql
