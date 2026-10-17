-- A confirmed reservation becomes a realized service for finance and NFS-e
-- reporting once its scheduled end is in the past. This is a read-model rule:
-- it deliberately does not mutate the operational appointment status or create
-- payment/collection side effects.

create or replace function public.service_admin_finance_nfse_export(p_month date, p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_month_start date:=date_trunc('month',p_month)::date;
  v_month_end date:=(date_trunc('month',p_month)+interval '1 month')::date;
  v_start timestamptz:=(v_month_start::timestamp at time zone 'America/Sao_Paulo');
  v_end timestamptz:=(v_month_end::timestamp at time zone 'America/Sao_Paulo');
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID'; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.service_at,x.appointment_id),'[]'::jsonb) into v_rows
  from (
    select a.id appointment_id,a.public_code,a.start_at service_at,to_char(a.start_at at time zone 'America/Sao_Paulo','DD/MM/YYYY') date,
      coalesce(c.name,'') client,coalesce(c.cpf_cnpj,'') cpf_cnpj,coalesce(c.address,'') address,coalesce(c.email,'') email,
      coalesce(a.service_name_snapshot,s.name,'') service,coalesce(a.commercial_value,0)::numeric(12,2) value,
      public.appointment_contract_coverage_amount(a.id)::numeric(12,2) contract_settled,
      round(greatest(coalesce(a.commercial_value,0)-public.appointment_contract_coverage_amount(a.id),0),2)::numeric(12,2) outstanding,
      a.financial_status,a.status appointment_status,s.operation_scope,coalesce(pm.payment_method,'Não recebido') payment_method,
      case s.operation_scope when 'BLACKSHEEP' then 'BlackSheep' when 'SABRINA' then 'Sabrina Pierri' else coalesce(s.operation_scope,'') end operation
    from public.appointments a
    left join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    left join lateral (
      select string_agg(q.label,' + ' order by q.label) payment_method from (
        select distinct case pt.method when 'PIX' then 'Pix' when 'CARD' then 'Cartão' when 'CASH' then 'Dinheiro' when 'TRANSFER' then 'Transferência' when 'CREDIT' then 'Crédito' when 'COURTESY' then 'Cortesia' when 'OTHER' then 'Outro' else 'Método não mapeado' end label
        from public.payment_transactions pt
        where pt.appointment_id=a.id and not pt.is_test and pt.transaction_type='CHARGE' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
        union
        select 'Saldo do cliente' where exists(select 1 from public.customer_balance_movements cbm where cbm.appointment_id=a.id and not cbm.is_test and cbm.movement_type='APPLY_TO_APPOINTMENT' and cbm.direction='DEBIT')
      ) q
    ) pm on true
    where not a.is_test
      and (a.status in('COMPLETED','NO_SHOW') or (a.status='CONFIRMED' and a.end_at<=now()))
      and a.start_at>=v_start and a.start_at<v_end and (v_scope is null or s.operation_scope=v_scope)
  ) x;

  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'timezone','America/Sao_Paulo','rows',v_rows);
end;
$$;

create or replace function public.service_admin_finance_month_close(p_month date, p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_month_start date:=date_trunc('month',p_month)::date;
  v_month_end date:=(date_trunc('month',p_month)+interval '1 month')::date;
  v_start timestamptz:=(v_month_start::timestamp at time zone 'America/Sao_Paulo');
  v_end timestamptz:=(v_month_end::timestamp at time zone 'America/Sao_Paulo');
  v_count integer:=0; v_contracted numeric(12,2):=0; v_gross_settled numeric(12,2):=0; v_contract_refunded numeric(12,2):=0; v_net_settled numeric(12,2):=0; v_outstanding numeric(12,2):=0;
  v_cash_received numeric(12,2):=0; v_cash_refunded numeric(12,2):=0; v_balance_open numeric(12,2):=0; v_balance_credited numeric(12,2):=0; v_balance_applied numeric(12,2):=0; v_balance_expired numeric(12,2):=0;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID'; end if;

  select count(*)::integer,coalesce(sum(a.commercial_value),0)::numeric(12,2),coalesce(sum(x.gross_settled),0)::numeric(12,2),coalesce(sum(x.refunded),0)::numeric(12,2)
  into v_count,v_contracted,v_gross_settled,v_contract_refunded
  from public.appointments a join public.services s on s.id=a.service_id
  left join lateral (
    select coalesce((select sum(pt.contract_amount_settled) from public.payment_transactions pt where pt.appointment_id=a.id and not pt.is_test and pt.transaction_type='CHARGE' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)
      +coalesce((select sum(cbm.amount) from public.customer_balance_movements cbm where cbm.appointment_id=a.id and not cbm.is_test and cbm.movement_type='APPLY_TO_APPOINTMENT' and cbm.direction='DEBIT'),0) as gross_settled,
      coalesce((select sum(pt.contract_amount_settled) from public.payment_transactions pt where pt.appointment_id=a.id and not pt.is_test and pt.transaction_type='REFUND' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','REFUNDED')),0) as refunded
  ) x on true
  where not a.is_test
    and (a.status in('COMPLETED','NO_SHOW') or (a.status='CONFIRMED' and a.end_at<=now()))
    and a.start_at>=v_start and a.start_at<v_end and (v_scope is null or s.operation_scope=v_scope);

  v_net_settled:=round(greatest(v_gross_settled-v_contract_refunded,0),2);
  v_outstanding:=round(greatest(v_contracted-v_net_settled,0),2);

  select coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='CHARGE' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='REFUND' and pt.status in('APPROVED','REFUNDED')),0)::numeric(12,2)
  into v_cash_received,v_cash_refunded
  from public.payment_transactions pt join public.appointments a on a.id=pt.appointment_id join public.services s on s.id=a.service_id
  where not pt.is_test and not a.is_test and coalesce(pt.paid_at,pt.created_at)>=v_start and coalesce(pt.paid_at,pt.created_at)<v_end and (v_scope is null or s.operation_scope=v_scope);

  if v_scope is null then
    select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2) into v_balance_open
    from public.customer_balance_movements cbm where cbm.direction='CREDIT' and not cbm.is_test and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>now();
  else
    select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2) into v_balance_open
    from public.customer_balance_movements cbm join public.appointments a on a.id=cbm.appointment_id join public.services s on s.id=a.service_id
    where cbm.direction='CREDIT' and not cbm.is_test and not a.is_test and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>now() and s.operation_scope=v_scope;
  end if;

  select coalesce(sum(cbm.amount) filter(where cbm.direction='CREDIT'),0)::numeric(12,2),coalesce(sum(cbm.amount) filter(where cbm.direction='DEBIT'),0)::numeric(12,2)
  into v_balance_credited,v_balance_applied
  from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where not cbm.is_test and (a.id is null or not a.is_test) and cbm.created_at>=v_start and cbm.created_at<v_end and (v_scope is null or s.operation_scope=v_scope);

  select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2) into v_balance_expired
  from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where cbm.direction='CREDIT' and not cbm.is_test and (a.id is null or not a.is_test) and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>=v_start and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')<v_end and (v_scope is null or s.operation_scope=v_scope);

  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'service_count',v_count,'revenue',round(v_contracted,2),
    'services',jsonb_build_object('service_count',v_count,'contracted',round(v_contracted,2),'statuses',jsonb_build_array('COMPLETED','NO_SHOW','CONFIRMED_AFTER_END')),
    'contract',jsonb_build_object('gross_settled',round(v_gross_settled,2),'refunded',round(v_contract_refunded,2),'net_settled',v_net_settled,'outstanding',v_outstanding),
    'cash',jsonb_build_object('received',round(v_cash_received,2),'refunded',round(v_cash_refunded,2),'net',round(v_cash_received-v_cash_refunded,2)),
    'customer_balance',jsonb_build_object('open_liability',round(v_balance_open,2),'credited_in_month',round(v_balance_credited,2),'applied_in_month',round(v_balance_applied,2),'expired_in_month',round(v_balance_expired,2),'validity_months',12,'accounting_classification','LIABILITY_NOT_REVENUE'),
    'range',jsonb_build_object('start_at',v_start,'end_at',v_end),'timezone','America/Sao_Paulo');
end;
$$;
