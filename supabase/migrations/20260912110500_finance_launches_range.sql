create or replace function public.service_admin_finance_launches_range(
  p_from timestamptz,
  p_to timestamptz,
  p_operation_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope, ''))), '');
  v_receivables jsonb;
  v_payments jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if v_scope is not null and v_scope not in ('BLACKSHEEP', 'SABRINA') then
    raise exception using errcode = 'P0001', message = 'FINANCE_OPERATION_SCOPE_INVALID';
  end if;

  if p_from is null or p_to is null or p_to <= p_from then
    raise exception using errcode = 'P0001', message = 'FINANCE_PERIOD_INVALID';
  end if;

  if p_to - p_from > interval '367 days' then
    raise exception using errcode = 'P0001', message = 'FINANCE_PERIOD_TOO_LARGE';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.start_at desc, x.appointment_id desc), '[]'::jsonb)
  into v_receivables
  from (
    select
      a.id appointment_id,
      a.public_code,
      a.start_at,
      a.status::text status,
      a.financial_status::text financial_status,
      coalesce(a.service_name_snapshot, s.name, 'Serviço') service_name,
      s.operation_scope,
      c.id customer_id,
      c.name customer_name,
      c.cpf_cnpj,
      c.email,
      coalesce(a.commercial_value, 0)::numeric(12,2) commercial_value,
      public.appointment_net_contract_settled_amount(a.id)::numeric(12,2) net_paid,
      round(
        greatest(
          coalesce(a.commercial_value, 0) - public.appointment_net_contract_settled_amount(a.id),
          0
        ),
        2
      )::numeric(12,2) remaining_due
    from public.appointments a
    join public.customers c on c.id = a.primary_customer_id
    left join public.services s on s.id = a.service_id
    where not a.is_test
      and coalesce(a.commercial_value, 0) > 0
      and a.status::text not in ('CANCELLED', 'EXPIRED')
      and a.start_at >= p_from
      and a.start_at < p_to
      and public.appointment_net_contract_settled_amount(a.id) < coalesce(a.commercial_value, 0) - 0.009
      and (v_scope is null or s.operation_scope = v_scope)
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc, x.transaction_id desc), '[]'::jsonb)
  into v_payments
  from (
    select
      pt.id transaction_id,
      pt.appointment_id,
      pt.provider,
      pt.method,
      pt.status,
      coalesce(pt.contract_amount_settled, 0)::numeric(12,2) gross_amount,
      coalesce(refunds.refunded_amount, 0)::numeric(12,2) refunded_amount,
      round(
        greatest(coalesce(pt.contract_amount_settled, 0) - coalesce(refunds.refunded_amount, 0), 0),
        2
      )::numeric(12,2) amount,
      coalesce(pt.paid_at, pt.created_at) paid_at,
      pt.notes,
      pt.created_by_admin_id,
      au.display_name registered_by,
      a.public_code,
      a.start_at appointment_start_at,
      coalesce(a.service_name_snapshot, s.name, 'Serviço') service_name,
      s.operation_scope,
      c.id customer_id,
      c.name customer_name,
      (
        pt.provider = 'MANUAL'
        and pt.status = 'APPROVED'
        and coalesce(refunds.refunded_amount, 0) = 0
      ) editable
    from public.payment_transactions pt
    join public.appointments a on a.id = pt.appointment_id
    join public.customers c on c.id = a.primary_customer_id
    left join public.services s on s.id = a.service_id
    left join public.admin_users au on au.id = pt.created_by_admin_id
    left join lateral (
      select coalesce(sum(r.contract_amount_settled), 0) refunded_amount
      from public.payment_transactions r
      where r.parent_transaction_id = pt.id
        and not r.is_test
        and r.transaction_type = 'REFUND'
        and r.payment_purpose = 'CONTRACT'
        and r.status in ('APPROVED', 'REFUNDED')
    ) refunds on true
    where not pt.is_test
      and not a.is_test
      and pt.transaction_type = 'CHARGE'
      and pt.payment_purpose = 'CONTRACT'
      and pt.status in ('APPROVED', 'PARTIALLY_REFUNDED', 'REFUNDED')
      and coalesce(pt.paid_at, pt.created_at) >= p_from
      and coalesce(pt.paid_at, pt.created_at) < p_to
      and (v_scope is null or s.operation_scope = v_scope)
  ) x;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'operation_scope', v_scope,
    'timezone', 'America/Sao_Paulo',
    'receivables', v_receivables,
    'payments', v_payments
  );
end;
$function$;
