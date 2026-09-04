-- Item B: align NFS-e export labels with the valid payment_transactions.method contract.
-- This only changes the read model; no issued record or payment transaction is mutated.
create or replace function public.service_admin_finance_nfse_export(
  p_month date,
  p_operation_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_month_start date:=date_trunc('month',p_month)::date;
  v_month_end date:=(date_trunc('month',p_month)+interval '1 month')::date;
  v_start timestamptz:=(v_month_start::timestamp at time zone 'America/Sao_Paulo');
  v_end timestamptz:=(v_month_end::timestamp at time zone 'America/Sao_Paulo');
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then
    raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.service_at,x.appointment_id),'[]'::jsonb)
    into v_rows
  from (
    select
      a.id appointment_id,
      a.public_code,
      a.start_at service_at,
      to_char(a.start_at at time zone 'America/Sao_Paulo','DD/MM/YYYY') date,
      coalesce(c.name,'') client,
      coalesce(c.cpf_cnpj,'') cpf_cnpj,
      coalesce(c.address,'') address,
      coalesce(c.email,'') email,
      coalesce(a.service_name_snapshot,s.name,'') service,
      coalesce(a.commercial_value,0)::numeric(12,2) value,
      public.appointment_contract_coverage_amount(a.id)::numeric(12,2) contract_settled,
      round(greatest(
        coalesce(a.commercial_value,0)-public.appointment_contract_coverage_amount(a.id),
        0
      ),2)::numeric(12,2) outstanding,
      a.financial_status,
      a.status appointment_status,
      s.operation_scope,
      coalesce(pm.payment_method,'Não recebido') payment_method,
      case s.operation_scope
        when 'BLACKSHEEP' then 'BlackSheep'
        when 'SABRINA' then 'Sabrina Pierri'
        else coalesce(s.operation_scope,'')
      end operation
    from public.appointments a
    left join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    left join lateral (
      select string_agg(q.label,' + ' order by q.label) payment_method
      from (
        select distinct
          case pt.method
            when 'PIX' then 'Pix'
            when 'CARD' then 'Cartão'
            when 'CASH' then 'Dinheiro'
            when 'TRANSFER' then 'Transferência'
            when 'CREDIT' then 'Crédito'
            when 'COURTESY' then 'Cortesia'
            when 'OTHER' then 'Outro'
            else 'Método não mapeado'
          end label
        from public.payment_transactions pt
        where pt.appointment_id=a.id
          and pt.transaction_type='CHARGE'
          and pt.payment_purpose='CONTRACT'
          and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
        union
        select 'Saldo do cliente'
        where exists(
          select 1
          from public.customer_balance_movements cbm
          where cbm.appointment_id=a.id
            and cbm.movement_type='APPLY_TO_APPOINTMENT'
            and cbm.direction='DEBIT'
        )
      ) q
    ) pm on true
    where a.status in('COMPLETED','NO_SHOW')
      and a.start_at>=v_start
      and a.start_at<v_end
      and (v_scope is null or s.operation_scope=v_scope)
  ) x;

  return jsonb_build_object(
    'month',to_char(v_month_start,'YYYY-MM'),
    'operation_scope',v_scope,
    'timezone','America/Sao_Paulo',
    'rows',v_rows
  );
end;
$function$;

revoke all on function public.service_admin_finance_nfse_export(date,text,uuid) from public;
revoke all on function public.service_admin_finance_nfse_export(date,text,uuid) from anon;
revoke all on function public.service_admin_finance_nfse_export(date,text,uuid) from authenticated;
grant execute on function public.service_admin_finance_nfse_export(date,text,uuid) to service_role;
