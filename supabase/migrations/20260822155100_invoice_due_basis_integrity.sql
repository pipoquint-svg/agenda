-- Issue #72 hardening: make the approved invoice due-date basis explicit and self-validating.
-- Approved rule: service start + invoice_due_days.

alter table public.appointments
  add column invoice_due_base_at timestamptz;

comment on column public.appointments.invoice_due_basis is
  'Authoritative basis identifier for invoiced appointments. V1 approved value: SERVICE_START.';
comment on column public.appointments.invoice_due_base_at is
  'Exact service-start timestamp used as the base for invoice due-date calculation.';
comment on column public.appointments.invoice_due_days_snapshot is
  'Customer invoice_due_days snapshotted when INVOICE is authorized/confirmed.';

create or replace function public.enforce_invoice_due_basis_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.billing_mode_snapshot = 'INVOICE' then
    if new.invoice_due_basis is distinct from 'SERVICE_START' then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_BASIS_REQUIRED';
    end if;
    if new.invoice_due_days_snapshot is null or new.invoice_due_days_snapshot < 0 then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
    end if;

    -- core_start_at is the explicit contracted service start in the current domain;
    -- start_at is the compatibility fallback for appointments created before schedule phases.
    new.invoice_due_base_at := coalesce(new.invoice_due_base_at, new.core_start_at, new.start_at);
    new.invoice_due_at := new.invoice_due_base_at
      + make_interval(days => new.invoice_due_days_snapshot);
  else
    new.invoice_due_basis := null;
    new.invoice_due_base_at := null;
    new.invoice_due_days_snapshot := null;
    new.invoice_due_at := null;
    new.invoice_authorized_by_admin_id := null;
  end if;

  return new;
end;
$$;

create trigger appointments_invoice_due_basis_integrity_trg
before insert or update of billing_mode_snapshot, invoice_due_basis, invoice_due_base_at,
  invoice_due_days_snapshot, invoice_due_at, core_start_at, start_at
on public.appointments
for each row execute function public.enforce_invoice_due_basis_integrity();

-- Backfill only already-explicit INVOICE rows. No customer or due-days rule is invented.
update public.appointments
set invoice_due_basis = 'SERVICE_START',
    invoice_due_days_snapshot = case
      when invoice_due_days_snapshot is not null then invoice_due_days_snapshot
      when invoice_due_at is not null and coalesce(core_start_at, start_at) is not null
        then greatest(0, round(extract(epoch from (invoice_due_at - coalesce(core_start_at, start_at))) / 86400)::integer)
      else null
    end,
    invoice_due_base_at = coalesce(core_start_at, start_at)
where billing_mode_snapshot = 'INVOICE'
  and invoice_due_days_snapshot is not null;

create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_base timestamptz;
  v_due_at timestamptz;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appt
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = v_appt.primary_customer_id
    and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  if v_terms.invoice_due_days is null then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
  end if;

  v_before := to_jsonb(v_appt);
  v_due_base := coalesce(v_appt.core_start_at, v_appt.start_at);
  v_due_at := v_due_base + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
  set billing_mode_snapshot = 'INVOICE',
      invoice_due_basis = 'SERVICE_START',
      invoice_due_base_at = v_due_base,
      invoice_due_days_snapshot = v_terms.invoice_due_days,
      invoice_due_at = v_due_at,
      invoice_authorized_by_admin_id = p_admin_id,
      financial_status = 'UNPAID_AUTHORIZED',
      updated_at = now()
  where id = p_appointment_id
  returning to_jsonb(appointments.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    v_before, v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_basis', 'SERVICE_START',
    'invoice_due_base_at', v_due_base,
    'invoice_due_days', v_terms.invoice_due_days,
    'invoice_due_at', v_due_at
  );
end;
$$;

revoke all on function public.enforce_invoice_due_basis_integrity() from public, anon, authenticated, service_role;
revoke all on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  to service_role;
