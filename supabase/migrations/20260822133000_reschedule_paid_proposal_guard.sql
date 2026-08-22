-- A paid reschedule penalty must never be orphaned by replacing its protected slot.
-- The existing implementation is retained as an internal helper; the public service RPC
-- adds the invariant before delegating to it.

alter function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  rename to service_admin_create_reschedule_hold_unchecked;

revoke all on function public.service_admin_create_reschedule_hold_unchecked(uuid,timestamptz,timestamptz,uuid)
  from public, anon, authenticated, service_role;

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz default now(),
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.appointment_policy_actions a
    join public.payment_transactions pt
      on pt.id = a.penalty_payment_transaction_id
    where a.appointment_id = p_appointment_id
      and a.action_type = 'RESCHEDULE'
      and a.status in ('PREVIEW','AWAITING_PENALTY_PAYMENT')
      and a.penalty_payment_transaction_id is not null
      and pt.payment_purpose = 'RESCHEDULE_PENALTY'
      and pt.status = 'APPROVED'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'RESCHEDULE_PAID_PROPOSAL_MUST_BE_APPLIED_OR_REVERSED';
  end if;

  return public.service_admin_create_reschedule_hold_unchecked(
    p_appointment_id,
    p_requested_start_at,
    p_requested_at,
    p_admin_id
  );
end;
$$;

revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  to service_role;
