create domain public.change_penalty_type as text
  check (value in ('NONE','FIXED','PERCENT'));

create table public.service_change_policies (
  service_id uuid primary key references public.services(id) on delete cascade,
  notice_hours integer not null default 48 check (notice_hours >= 0),

  reschedule_first_penalty_type public.change_penalty_type not null default 'NONE',
  reschedule_first_penalty_value numeric(12,2) not null default 0 check (reschedule_first_penalty_value >= 0),
  reschedule_repeat_penalty_type public.change_penalty_type not null default 'PERCENT',
  reschedule_repeat_penalty_value numeric(12,2) not null default 20 check (reschedule_repeat_penalty_value >= 0),
  reschedule_late_penalty_type public.change_penalty_type not null default 'PERCENT',
  reschedule_late_penalty_value numeric(12,2) not null default 20 check (reschedule_late_penalty_value >= 0),

  cancellation_early_penalty_type public.change_penalty_type not null default 'NONE',
  cancellation_early_penalty_value numeric(12,2) not null default 0 check (cancellation_early_penalty_value >= 0),
  cancellation_late_penalty_type public.change_penalty_type not null default 'PERCENT',
  cancellation_late_penalty_value numeric(12,2) not null default 20 check (cancellation_late_penalty_value >= 0),

  cancellation_early_refund_allowed boolean not null default true,
  cancellation_early_credit_allowed boolean not null default true,
  cancellation_late_refund_allowed boolean not null default true,
  cancellation_late_credit_allowed boolean not null default true,
  cancellation_credit_validity_days integer not null default 90 check (cancellation_credit_validity_days > 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint service_change_policy_first_penalty_shape check (
    (reschedule_first_penalty_type = 'NONE' and reschedule_first_penalty_value = 0)
    or (reschedule_first_penalty_type = 'FIXED')
    or (reschedule_first_penalty_type = 'PERCENT' and reschedule_first_penalty_value <= 100)
  ),
  constraint service_change_policy_repeat_penalty_shape check (
    (reschedule_repeat_penalty_type = 'NONE' and reschedule_repeat_penalty_value = 0)
    or (reschedule_repeat_penalty_type = 'FIXED')
    or (reschedule_repeat_penalty_type = 'PERCENT' and reschedule_repeat_penalty_value <= 100)
  ),
  constraint service_change_policy_late_reschedule_penalty_shape check (
    (reschedule_late_penalty_type = 'NONE' and reschedule_late_penalty_value = 0)
    or (reschedule_late_penalty_type = 'FIXED')
    or (reschedule_late_penalty_type = 'PERCENT' and reschedule_late_penalty_value <= 100)
  ),
  constraint service_change_policy_early_cancel_penalty_shape check (
    (cancellation_early_penalty_type = 'NONE' and cancellation_early_penalty_value = 0)
    or (cancellation_early_penalty_type = 'FIXED')
    or (cancellation_early_penalty_type = 'PERCENT' and cancellation_early_penalty_value <= 100)
  ),
  constraint service_change_policy_late_cancel_penalty_shape check (
    (cancellation_late_penalty_type = 'NONE' and cancellation_late_penalty_value = 0)
    or (cancellation_late_penalty_type = 'FIXED')
    or (cancellation_late_penalty_type = 'PERCENT' and cancellation_late_penalty_value <= 100)
  )
);

alter table public.coupons
  add column source text not null default 'PROMOTION'
    check (source in ('PROMOTION','CANCELLATION_CREDIT')),
  add column customer_id uuid references public.customers(id) on delete restrict,
  add column source_appointment_id uuid references public.appointments(id) on delete restrict,
  add column max_uses integer check (max_uses is null or max_uses > 0),
  add column used_count integer not null default 0 check (used_count >= 0),
  add constraint coupons_usage_limit_check
    check (max_uses is null or used_count <= max_uses),
  add constraint cancellation_credit_coupon_shape_check
    check (
      source <> 'CANCELLATION_CREDIT'
      or (
        discount_type = 'FIXED'
        and customer_id is not null
        and source_appointment_id is not null
        and max_uses = 1
        and valid_until is not null
      )
    );

create unique index coupons_cancellation_credit_appointment_uq
  on public.coupons (source_appointment_id)
  where source = 'CANCELLATION_CREDIT';

create table public.appointment_policy_actions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  action_type text not null check (action_type in ('RESCHEDULE','CANCEL')),
  status text not null default 'PREVIEW'
    check (status in (
      'PREVIEW',
      'AWAITING_PENALTY_PAYMENT',
      'APPLIED',
      'PENDING_REFUND',
      'REFUNDED',
      'CREDIT_ISSUED',
      'FAILED',
      'VOIDED'
    )),
  settlement_choice text check (settlement_choice in ('REFUND','CREDIT')),

  requested_at timestamptz not null default now(),
  original_start_at timestamptz not null,
  requested_new_start_at timestamptz,
  hours_before_start numeric(12,2) not null,
  notice_hours_snapshot integer not null check (notice_hours_snapshot >= 0),
  is_inside_notice_window boolean not null,
  prior_customer_reschedules integer not null default 0 check (prior_customer_reschedules >= 0),

  contract_value_snapshot numeric(12,2) not null check (contract_value_snapshot >= 0),
  net_paid_snapshot numeric(12,2) not null check (net_paid_snapshot >= 0),
  penalty_type public.change_penalty_type not null,
  penalty_value numeric(12,2) not null default 0 check (penalty_value >= 0),
  penalty_amount numeric(12,2) not null default 0 check (penalty_amount >= 0),
  penalty_due_now numeric(12,2) not null default 0 check (penalty_due_now >= 0),
  refund_allowed boolean not null default false,
  credit_allowed boolean not null default false,
  credit_validity_days_snapshot integer check (credit_validity_days_snapshot is null or credit_validity_days_snapshot > 0),
  refundable_amount numeric(12,2) not null default 0 check (refundable_amount >= 0),
  credit_amount numeric(12,2) not null default 0 check (credit_amount >= 0),
  cancellation_penalty_outstanding numeric(12,2) not null default 0 check (cancellation_penalty_outstanding >= 0),

  refund_transaction_id uuid references public.payment_transactions(id) on delete restrict,
  generated_coupon_id uuid references public.coupons(id) on delete restrict,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index appointment_policy_actions_appointment_idx
  on public.appointment_policy_actions (appointment_id, created_at);

create index appointment_policy_actions_applied_reschedule_idx
  on public.appointment_policy_actions (appointment_id)
  where action_type = 'RESCHEDULE' and status = 'APPLIED';

create or replace function public.appointment_net_paid_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path = public
as $$
  select round(greatest(
    coalesce(sum(case
      when pt.transaction_type = 'CHARGE'
       and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
      then pt.cash_amount else 0 end), 0)
    -
    coalesce(sum(case
      when pt.transaction_type = 'REFUND'
       and pt.status in ('APPROVED','REFUNDED')
      then pt.cash_amount else 0 end), 0),
    0
  ), 2)::numeric(12,2)
  from public.payment_transactions pt
  where pt.appointment_id = p_appointment_id;
$$;

create or replace function public.calculate_change_penalty(
  p_type public.change_penalty_type,
  p_value numeric,
  p_contract_value numeric
)
returns numeric(12,2)
language sql
immutable
set search_path = public
as $$
  select case p_type
    when 'NONE' then 0::numeric(12,2)
    when 'FIXED' then round(p_value, 2)::numeric(12,2)
    when 'PERCENT' then round(p_contract_value * p_value / 100, 2)::numeric(12,2)
  end;
$$;

create or replace function public.calculate_appointment_change_policy(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_policy public.service_change_policies%rowtype;
  v_hours_before numeric(12,2);
  v_inside_window boolean;
  v_prior_reschedules integer;
  v_contract_value numeric(12,2);
  v_paid numeric(12,2);
  v_penalty_type public.change_penalty_type;
  v_penalty_value numeric(12,2) := 0;
  v_penalty numeric(12,2) := 0;
  v_penalty_due_now numeric(12,2) := 0;
  v_refund_allowed boolean := false;
  v_credit_allowed boolean := false;
  v_refundable numeric(12,2) := 0;
  v_credit numeric(12,2) := 0;
  v_outstanding numeric(12,2) := 0;
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_ACTION';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_policy
  from public.service_change_policies
  where service_id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_CHANGE_POLICY_NOT_CONFIGURED';
  end if;

  v_hours_before := round(extract(epoch from (v_appointment.start_at - p_requested_at)) / 3600.0, 2);
  v_inside_window := v_hours_before < v_policy.notice_hours;

  select count(*)::integer
  into v_prior_reschedules
  from public.appointment_policy_actions apa
  where apa.appointment_id = p_appointment_id
    and apa.action_type = 'RESCHEDULE'
    and apa.status = 'APPLIED';

  v_contract_value := coalesce(v_appointment.commercial_value, 0);
  v_paid := public.appointment_net_paid_amount(p_appointment_id);

  if p_action_type = 'RESCHEDULE' then
    if v_inside_window then
      v_penalty_type := v_policy.reschedule_late_penalty_type;
      v_penalty_value := v_policy.reschedule_late_penalty_value;
    elsif v_prior_reschedules > 0 then
      v_penalty_type := v_policy.reschedule_repeat_penalty_type;
      v_penalty_value := v_policy.reschedule_repeat_penalty_value;
    else
      v_penalty_type := v_policy.reschedule_first_penalty_type;
      v_penalty_value := v_policy.reschedule_first_penalty_value;
    end if;

    v_penalty := public.calculate_change_penalty(v_penalty_type, v_penalty_value, v_contract_value);
    v_penalty_due_now := v_penalty;
  else
    if v_inside_window then
      v_penalty_type := v_policy.cancellation_late_penalty_type;
      v_penalty_value := v_policy.cancellation_late_penalty_value;
      v_refund_allowed := v_policy.cancellation_late_refund_allowed;
      v_credit_allowed := v_policy.cancellation_late_credit_allowed;
    else
      v_penalty_type := v_policy.cancellation_early_penalty_type;
      v_penalty_value := v_policy.cancellation_early_penalty_value;
      v_refund_allowed := v_policy.cancellation_early_refund_allowed;
      v_credit_allowed := v_policy.cancellation_early_credit_allowed;
    end if;

    v_penalty := public.calculate_change_penalty(v_penalty_type, v_penalty_value, v_contract_value);
    v_refundable := round(greatest(v_paid - v_penalty, 0), 2);
    v_credit := v_refundable;
    v_outstanding := round(greatest(v_penalty - v_paid, 0), 2);
  end if;

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'service_id', v_appointment.service_id,
    'action_type', p_action_type,
    'requested_at', p_requested_at,
    'original_start_at', v_appointment.start_at,
    'hours_before_start', v_hours_before,
    'notice_hours', v_policy.notice_hours,
    'inside_notice_window', v_inside_window,
    'prior_customer_reschedules', v_prior_reschedules,
    'contract_value', v_contract_value,
    'net_paid', v_paid,
    'penalty_type', v_penalty_type,
    'penalty_value', v_penalty_value,
    'penalty_amount', v_penalty,
    'penalty_due_now', v_penalty_due_now,
    'refund_allowed', v_refund_allowed,
    'credit_allowed', v_credit_allowed,
    'credit_validity_days', v_policy.cancellation_credit_validity_days,
    'refundable_amount', v_refundable,
    'credit_amount', v_credit,
    'cancellation_penalty_outstanding', v_outstanding
  );
end;
$$;

create or replace function public.issue_cancellation_credit_coupon(
  p_policy_action_id uuid
)
returns table (
  coupon_id uuid,
  code text,
  amount numeric(12,2),
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_customer_id uuid;
  v_code text;
  v_coupon_id uuid;
  v_expires_at timestamptz;
begin
  select * into v_action
  from public.appointment_policy_actions
  where id = p_policy_action_id
  for update;

  if not found or v_action.action_type <> 'CANCEL' then
    raise exception using errcode = 'P0001', message = 'INVALID_CANCELLATION_ACTION';
  end if;

  if not v_action.credit_allowed then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_CREDIT_NOT_ALLOWED';
  end if;

  if v_action.credit_amount <= 0 then
    raise exception using errcode = 'P0001', message = 'NO_CREDIT_AVAILABLE';
  end if;

  if v_action.credit_validity_days_snapshot is null then
    raise exception using errcode = 'P0001', message = 'CREDIT_VALIDITY_REQUIRED';
  end if;

  select a.primary_customer_id into v_customer_id
  from public.appointments a
  where a.id = v_action.appointment_id;

  if v_customer_id is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_CUSTOMER_REQUIRED';
  end if;

  v_expires_at := now() + make_interval(days => v_action.credit_validity_days_snapshot);
  v_code := 'CR-' || upper(substr(encode(gen_random_bytes(12), 'hex'), 1, 16));

  insert into public.coupons (
    code,
    discount_type,
    discount_value,
    valid_from,
    valid_until,
    is_active,
    source,
    customer_id,
    source_appointment_id,
    max_uses
  ) values (
    v_code,
    'FIXED',
    v_action.credit_amount,
    now(),
    v_expires_at,
    true,
    'CANCELLATION_CREDIT',
    v_customer_id,
    v_action.appointment_id,
    1
  ) returning id into v_coupon_id;

  update public.appointment_policy_actions
  set settlement_choice = 'CREDIT',
      status = 'CREDIT_ISSUED',
      generated_coupon_id = v_coupon_id,
      updated_at = now()
  where id = v_action.id;

  coupon_id := v_coupon_id;
  code := v_code;
  amount := v_action.credit_amount;
  expires_at := v_expires_at;
  return next;
end;
$$;

revoke all on function public.issue_cancellation_credit_coupon(uuid) from public, anon, authenticated;
grant execute on function public.issue_cancellation_credit_coupon(uuid) to service_role;
