-- Refund is the safe automatic default, not an admin settlement choice.
-- Only diverting customer money to CUSTOMER_BALANCE is an explicit financial
-- decision at cancellation time. Executing the provider/manual refund remains
-- separately protected by FINANCE_MANAGE in the Edge/API layer.

create or replace function public.enforce_cancellation_financial_settlement_permission()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.action_type='CANCEL' and new.settlement_choice='CUSTOMER_BALANCE' then
    perform public.service_admin_assert_financial_settlement_permission(new.created_by_admin_id);
  end if;
  return new;
end;
$$;

comment on function public.enforce_cancellation_financial_settlement_permission() is
'Allows REFUND as automatic safe default. CUSTOMER_BALANCE requires a finance-authorized actor; provider/manual refund execution is permission-gated separately.';
