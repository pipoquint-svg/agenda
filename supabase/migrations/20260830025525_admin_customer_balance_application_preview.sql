create or replace function public.service_admin_customer_balance_application_preview(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_customer_name text;
  v_balance numeric(12,2);
  v_due numeric(12,2);
  v_applicable numeric(12,2);
  v_balance_after numeric(12,2);
  v_due_after numeric(12,2);
  v_nearest_expiry timestamptz;
  v_legacy numeric(12,2) := 0;
begin
  if p_admin_id is null or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id;

  if not found then
    raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND';
  end if;
  if v_appointment.primary_customer_id is null then
    raise exception using errcode='P0001', message='APPOINTMENT_CUSTOMER_REQUIRED';
  end if;

  select name into v_customer_name
  from public.customers
  where id=v_appointment.primary_customer_id;

  v_balance := public.customer_balance_available(v_appointment.primary_customer_id);
  v_due := round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_contract_coverage_amount(p_appointment_id),0),2);
  v_applicable := round(least(v_balance,v_due),2);
  v_balance_after := round(greatest(v_balance-v_applicable,0),2);
  v_due_after := round(greatest(v_due-v_applicable,0),2);

  select coalesce(sum(amount),0)::numeric(12,2) into v_legacy
  from public.customer_balance_movements
  where customer_id=v_appointment.primary_customer_id
    and direction='DEBIT'
    and source_credit_movement_id is null;

  with lots as (
    select
      c.id,
      c.created_at,
      coalesce(c.expires_at,c.created_at+interval '12 months') as expires_at,
      greatest(c.amount-coalesce(sum(d.amount),0),0)::numeric(12,2) as remaining
    from public.customer_balance_movements c
    left join public.customer_balance_movements d
      on d.source_credit_movement_id=c.id and d.direction='DEBIT'
    where c.customer_id=v_appointment.primary_customer_id
      and c.direction='CREDIT'
      and coalesce(c.expires_at,c.created_at+interval '12 months')>now()
    group by c.id,c.created_at,c.expires_at,c.amount
  ), ordered as (
    select
      *,
      coalesce(sum(remaining) over (
        order by expires_at,created_at,id
        rows between unbounded preceding and 1 preceding
      ),0)::numeric(12,2) as prior_remaining
    from lots
  )
  select min(expires_at) into v_nearest_expiry
  from ordered
  where greatest(remaining-greatest(v_legacy-prior_remaining,0),0)>0;

  if v_balance<=0 then
    v_nearest_expiry := null;
  end if;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'public_code',v_appointment.public_code,
    'customer_id',v_appointment.primary_customer_id,
    'customer_name',v_customer_name,
    'balance_available',v_balance,
    'nearest_expiry',v_nearest_expiry,
    'amount_due',v_due,
    'amount_applicable',v_applicable,
    'balance_after',v_balance_after,
    'amount_due_after',v_due_after,
    'consumption_order','EARLIEST_EXPIRY_FIRST'
  );
end;
$function$;

revoke all on function public.service_admin_customer_balance_application_preview(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_customer_balance_application_preview(uuid,uuid) to service_role;
