-- Choosing refund or credit is a financial decision, even when cancellation itself
-- is operational. Enforce this invariant at the database boundary so a caller cannot
-- bypass the UI or Edge Function permission split.

create or replace function public.service_admin_assert_financial_settlement_permission(
  p_admin_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- Null actors are reserved for trusted internal/test service-role calls. User-facing
  -- Edge Functions always resolve and pass a concrete admin id.
  if p_admin_id is null then return; end if;

  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
end;
$$;

create or replace function public.enforce_cancellation_financial_settlement_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.action_type = 'CANCEL'
     and new.settlement_choice in ('REFUND','CREDIT') then
    perform public.service_admin_assert_financial_settlement_permission(new.created_by_admin_id);
  end if;
  return new;
end;
$$;

drop trigger if exists appointment_policy_actions_financial_settlement_guard
  on public.appointment_policy_actions;
create trigger appointment_policy_actions_financial_settlement_guard
before insert or update of settlement_choice, created_by_admin_id
on public.appointment_policy_actions
for each row
execute function public.enforce_cancellation_financial_settlement_permission();

revoke all on function public.service_admin_assert_financial_settlement_permission(uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_assert_financial_settlement_permission(uuid)
  to service_role;

revoke all on function public.enforce_cancellation_financial_settlement_permission()
  from public, anon, authenticated;
