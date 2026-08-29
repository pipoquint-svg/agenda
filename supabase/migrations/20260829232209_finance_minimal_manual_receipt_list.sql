create or replace function public.service_admin_list_manual_receipts(
  p_month date,
  p_operation_scope text,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
stable
set search_path to 'public','pg_temp'
as $$
declare
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_month_start date := date_trunc('month',p_month)::date;
  v_month_end date := (date_trunc('month',p_month)+interval '1 month')::date;
  v_start timestamptz := (v_month_start::timestamp at time zone 'America/Sao_Paulo');
  v_end timestamptz := (v_month_end::timestamp at time zone 'America/Sao_Paulo');
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then raise exception 'FINANCE_OPERATION_SCOPE_INVALID'; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc,x.transaction_id),'[]'::jsonb) into v_rows
  from (
    select
      pt.id as transaction_id,
      pt.appointment_id,
      pt.method,
      pt.status,
      pt.contract_amount_settled::numeric(12,2) as amount,
      pt.paid_at,
      pt.notes,
      pt.created_by_admin_id,
      au.display_name as registered_by,
      a.public_code,
      a.start_at as appointment_start_at,
      coalesce(a.service_name_snapshot,s.name,'Serviço') as service_name,
      s.operation_scope,
      c.id as customer_id,
      c.name as customer_name,
      not exists(
        select 1 from public.payment_transactions r
        where r.parent_transaction_id=pt.id
          and r.transaction_type='REFUND'
          and r.status in ('APPROVED','REFUNDED')
      ) and pt.status='APPROVED' as editable
    from public.payment_transactions pt
    join public.appointments a on a.id=pt.appointment_id
    join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    left join public.admin_users au on au.id=pt.created_by_admin_id
    where pt.provider='MANUAL'
      and pt.transaction_type='CHARGE'
      and pt.payment_purpose='CONTRACT'
      and pt.method in ('CASH','PIX')
      and coalesce(pt.paid_at,pt.created_at)>=v_start
      and coalesce(pt.paid_at,pt.created_at)<v_end
      and (v_scope is null or s.operation_scope=v_scope)
  ) x;

  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'timezone','America/Sao_Paulo','receipts',v_rows);
end;
$$;

revoke all on function public.service_admin_list_manual_receipts(date,text,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_list_manual_receipts(date,text,uuid) to service_role;
