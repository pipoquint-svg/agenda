-- Commercial terms for selected recurring/corporate customers.
-- No customer is enabled by default; production values are explicitly configured per customer.

create table public.customer_commercial_terms (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  can_prebook boolean not null default false,
  prebook_hold_minutes integer not null default 1440 check (prebook_hold_minutes > 0),
  max_active_prebooks integer not null default 1 check (max_active_prebooks > 0),
  requires_manual_confirmation boolean not null default true,
  billing_mode text not null default 'CHECKOUT'
    check (billing_mode in ('CHECKOUT','INVOICE')),
  invoice_due_days integer check (
    (billing_mode = 'CHECKOUT' and invoice_due_days is null)
    or (billing_mode = 'INVOICE' and invoice_due_days is not null and invoice_due_days >= 0)
  ),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customer_prebook_authorized_services (
  customer_id uuid not null references public.customers(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (customer_id, service_id)
);

create table public.pre_reservations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  employee_id uuid references public.employees(id) on delete restrict,
  start_at timestamptz not null,
  end_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE','CONFIRMED','CANCELLED','EXPIRED')),
  converted_appointment_id uuid references public.appointments(id) on delete restrict,
  created_by_admin_id uuid,
  confirmed_by_admin_id uuid,
  cancelled_by_admin_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  check (end_at > start_at),
  check (expires_at > created_at)
);

create index pre_reservations_customer_status_idx
  on public.pre_reservations (customer_id, status, expires_at);

create index pre_reservations_active_time_idx
  on public.pre_reservations (start_at, end_at)
  where status = 'ACTIVE';

alter table public.appointments
  add column billing_mode_snapshot text not null default 'CHECKOUT'
    check (billing_mode_snapshot in ('CHECKOUT','INVOICE')),
  add column invoice_due_at timestamptz,
  add column invoice_authorized_by_admin_id uuid,
  add column source_pre_reservation_id uuid references public.pre_reservations(id) on delete restrict;

alter table public.pre_reservations
  add constraint pre_reservations_converted_appointment_uq unique (converted_appointment_id);

create unique index appointments_source_pre_reservation_uq
  on public.appointments (source_pre_reservation_id)
  where source_pre_reservation_id is not null;

create unique index pre_reservations_idempotency_shape_uq
  on public.pre_reservations (customer_id, service_id, start_at, end_at)
  where status = 'ACTIVE';

create or replace function public.service_get_customer_commercial_terms(p_customer_id uuid)
returns table (
  customer_id uuid,
  can_prebook boolean,
  prebook_hold_minutes integer,
  max_active_prebooks integer,
  requires_manual_confirmation boolean,
  billing_mode text,
  invoice_due_days integer
)
language sql
security definer
set search_path = public
as $$
  select t.customer_id, t.can_prebook, t.prebook_hold_minutes,
         t.max_active_prebooks, t.requires_manual_confirmation,
         t.billing_mode, t.invoice_due_days
    from public.customer_commercial_terms t
   where t.customer_id = p_customer_id
     and t.is_active = true;
$$;

create or replace function public.service_expire_pre_reservations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.pre_reservations
     set status = 'EXPIRED', updated_at = now()
   where status = 'ACTIVE'
     and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_at timestamptz;
begin
  select * into v_appt
    from public.appointments
   where id = p_appointment_id
   for update;

  if not found then
    raise exception 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
    from public.customer_commercial_terms
   where customer_id = v_appt.primary_customer_id
     and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  v_due_at := coalesce(v_appt.start_at, now()) + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
     set billing_mode_snapshot = 'INVOICE',
         invoice_due_at = v_due_at,
         invoice_authorized_by_admin_id = p_admin_id,
         financial_status = 'UNPAID_AUTHORIZED',
         updated_at = now()
   where id = p_appointment_id;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    jsonb_build_object(
      'billing_mode', 'INVOICE',
      'invoice_due_days', v_terms.invoice_due_days,
      'invoice_due_at', v_due_at,
      'customer_id', v_appt.primary_customer_id
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_at', v_due_at
  );
end;
$$;
