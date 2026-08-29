create or replace function public.service_admin_record_manual_receipt(
  p_appointment_id uuid,
  p_method text,
  p_amount numeric,
  p_paid_at timestamptz,
  p_notes text,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_appointment public.appointments%rowtype;
  v_method text := upper(btrim(coalesce(p_method,'')));
  v_amount numeric(12,2) := round(coalesce(p_amount,0),2);
  v_paid_at timestamptz := coalesce(p_paid_at,now());
  v_notes text := nullif(btrim(coalesce(p_notes,'')),'');
  v_net_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_tx public.payment_transactions%rowtype;
  v_financial_status public.financial_status;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_method not in ('CASH','PIX') then raise exception 'MANUAL_RECEIPT_METHOD_INVALID'; end if;
  if v_amount <= 0 then raise exception 'MANUAL_RECEIPT_AMOUNT_INVALID'; end if;
  if v_paid_at > now() + interval '5 minutes' then raise exception 'MANUAL_RECEIPT_PAID_AT_FUTURE'; end if;
  if v_notes is not null and length(v_notes) > 500 then raise exception 'MANUAL_RECEIPT_NOTES_TOO_LONG'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.primary_customer_id is null then raise exception 'MANUAL_RECEIPT_CUSTOMER_REQUIRED'; end if;
  if v_appointment.status::text in ('CANCELLED','EXPIRED') then raise exception 'MANUAL_RECEIPT_APPOINTMENT_CLOSED'; end if;
  if coalesce(v_appointment.commercial_value,0) <= 0 then raise exception 'MANUAL_RECEIPT_CONTRACT_VALUE_REQUIRED'; end if;

  v_net_paid := public.appointment_net_contract_settled_amount(p_appointment_id);
  v_remaining := round(greatest(coalesce(v_appointment.commercial_value,0)-coalesce(v_net_paid,0),0),2);
  if v_amount > v_remaining + 0.009 then raise exception 'MANUAL_RECEIPT_EXCEEDS_BALANCE'; end if;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,
    contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',
    v_amount,0,v_amount,v_paid_at,p_admin_id,v_notes,'CONTRACT'
  ) returning * into v_tx;

  v_financial_status := public.refresh_appointment_financial_status(p_appointment_id);

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'PAYMENT_TRANSACTION',v_tx.id,'MANUAL_RECEIPT_RECORDED',null,
    jsonb_build_object(
      'appointment_id',p_appointment_id,
      'customer_id',v_appointment.primary_customer_id,
      'method',v_method,
      'amount',v_amount,
      'paid_at',v_paid_at,
      'financial_status',v_financial_status
    ),'ADMIN_UI'
  );

  return jsonb_build_object(
    'transaction',to_jsonb(v_tx),
    'appointment_id',p_appointment_id,
    'customer_id',v_appointment.primary_customer_id,
    'financial_status',v_financial_status,
    'net_paid',public.appointment_net_contract_settled_amount(p_appointment_id),
    'remaining_due',round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_net_contract_settled_amount(p_appointment_id),0),2)
  );
end;
$$;

create or replace function public.service_admin_reverse_manual_receipt(
  p_transaction_id uuid,
  p_reason text,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_original public.payment_transactions%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_refunded numeric(12,2);
  v_amount numeric(12,2);
  v_refund public.payment_transactions%rowtype;
  v_financial_status public.financial_status;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_reason is null then raise exception 'MANUAL_RECEIPT_REVERSAL_REASON_REQUIRED'; end if;
  if length(v_reason)>500 then raise exception 'MANUAL_RECEIPT_NOTES_TOO_LONG'; end if;

  select * into v_original from public.payment_transactions where id=p_transaction_id for update;
  if not found then raise exception 'MANUAL_RECEIPT_NOT_FOUND'; end if;
  if v_original.transaction_type<>'CHARGE' or v_original.provider<>'MANUAL' or v_original.payment_purpose<>'CONTRACT' or v_original.method not in ('CASH','PIX') then
    raise exception 'MANUAL_RECEIPT_NOT_REVERSIBLE';
  end if;

  select coalesce(sum(contract_amount_settled),0)::numeric(12,2)
    into v_refunded
  from public.payment_transactions
  where parent_transaction_id=v_original.id
    and transaction_type='REFUND'
    and status in ('APPROVED','REFUNDED');

  v_amount := round(greatest(v_original.contract_amount_settled-v_refunded,0),2);
  if v_amount<=0.009 then raise exception 'MANUAL_RECEIPT_ALREADY_REVERSED'; end if;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,
    contract_amount_settled,payment_discount_amount,cash_amount,
    parent_transaction_id,paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    v_original.appointment_id,'REFUND',v_original.method,'MANUAL','APPROVED',
    v_amount,0,v_amount,v_original.id,now(),p_admin_id,v_reason,'CONTRACT'
  ) returning * into v_refund;

  update public.payment_transactions set status='REFUNDED',updated_at=now() where id=v_original.id;
  v_financial_status := public.refresh_appointment_financial_status(v_original.appointment_id);

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'PAYMENT_TRANSACTION',v_original.id,'MANUAL_RECEIPT_REVERSED',
    jsonb_build_object('status',v_original.status,'amount',v_original.contract_amount_settled,'method',v_original.method),
    jsonb_build_object('status','REFUNDED','refund_transaction_id',v_refund.id,'reversed_amount',v_amount,'reason',v_reason,'financial_status',v_financial_status),
    'ADMIN_UI'
  );

  return jsonb_build_object(
    'original_transaction_id',v_original.id,
    'refund_transaction',to_jsonb(v_refund),
    'appointment_id',v_original.appointment_id,
    'financial_status',v_financial_status,
    'net_paid',public.appointment_net_contract_settled_amount(v_original.appointment_id)
  );
end;
$$;

create or replace function public.service_admin_edit_manual_receipt(
  p_transaction_id uuid,
  p_method text,
  p_amount numeric,
  p_paid_at timestamptz,
  p_notes text,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_original public.payment_transactions%rowtype;
  v_reversal jsonb;
  v_replacement jsonb;
  v_replacement_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  select * into v_original from public.payment_transactions where id=p_transaction_id;
  if not found then raise exception 'MANUAL_RECEIPT_NOT_FOUND'; end if;

  v_reversal := public.service_admin_reverse_manual_receipt(p_transaction_id,'Substituído por edição do recebimento manual',p_admin_id);
  v_replacement := public.service_admin_record_manual_receipt(v_original.appointment_id,p_method,p_amount,p_paid_at,p_notes,p_admin_id);
  v_replacement_id := nullif(v_replacement #>> '{transaction,id}','')::uuid;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'PAYMENT_TRANSACTION',p_transaction_id,'MANUAL_RECEIPT_EDITED',
    jsonb_build_object('method',v_original.method,'amount',v_original.contract_amount_settled,'paid_at',v_original.paid_at),
    jsonb_build_object('replacement_transaction_id',v_replacement_id,'method',upper(btrim(coalesce(p_method,''))),'amount',round(coalesce(p_amount,0),2),'paid_at',coalesce(p_paid_at,now())),
    'ADMIN_UI'
  );

  return jsonb_build_object('reversal',v_reversal,'replacement',v_replacement);
end;
$$;

create or replace function public.service_admin_list_receivable_appointments(
  p_search text,
  p_limit integer,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
stable
set search_path to 'public','pg_temp'
as $$
declare
  v_search text := nullif(lower(btrim(coalesce(p_search,''))),'');
  v_limit integer := least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.start_at desc),'[]'::jsonb) into v_rows
  from (
    select
      a.id as appointment_id,
      a.public_code,
      a.start_at,
      a.status::text as status,
      a.financial_status::text as financial_status,
      coalesce(a.service_name_snapshot,s.name,'Serviço') as service_name,
      s.operation_scope,
      c.id as customer_id,
      c.name as customer_name,
      c.cpf_cnpj,
      c.email,
      coalesce(a.commercial_value,0)::numeric(12,2) as commercial_value,
      public.appointment_net_contract_settled_amount(a.id)::numeric(12,2) as net_paid,
      round(greatest(coalesce(a.commercial_value,0)-public.appointment_net_contract_settled_amount(a.id),0),2)::numeric(12,2) as remaining_due
    from public.appointments a
    join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    where coalesce(a.commercial_value,0)>0
      and a.status::text not in ('CANCELLED','EXPIRED')
      and public.appointment_net_contract_settled_amount(a.id) < coalesce(a.commercial_value,0)-0.009
      and (
        v_search is null
        or lower(coalesce(a.public_code,'')) like '%'||v_search||'%'
        or lower(c.name) like '%'||v_search||'%'
        or lower(coalesce(c.email,'')) like '%'||v_search||'%'
        or lower(coalesce(c.phone,'')) like '%'||v_search||'%'
        or regexp_replace(coalesce(c.cpf_cnpj,''),'[^0-9]','','g') like '%'||regexp_replace(v_search,'[^0-9]','','g')||'%'
      )
    order by a.start_at desc
    limit v_limit
  ) x;

  return jsonb_build_object('appointments',v_rows);
end;
$$;

create or replace function public.service_admin_finance_month_close(
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
  v_count integer;
  v_revenue numeric(12,2);
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then raise exception 'FINANCE_OPERATION_SCOPE_INVALID'; end if;

  select count(*)::integer,coalesce(sum(a.commercial_value),0)::numeric(12,2)
    into v_count,v_revenue
  from public.appointments a
  left join public.services s on s.id=a.service_id
  where a.status::text='COMPLETED'
    and a.start_at>=v_start and a.start_at<v_end
    and (v_scope is null or s.operation_scope=v_scope);

  return jsonb_build_object(
    'month',to_char(v_month_start,'YYYY-MM'),
    'operation_scope',v_scope,
    'service_count',v_count,
    'revenue',round(v_revenue,2),
    'range',jsonb_build_object('start_at',v_start,'end_at',v_end),
    'timezone','America/Sao_Paulo'
  );
end;
$$;

create or replace function public.service_admin_finance_nfse_export(
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

  select coalesce(jsonb_agg(to_jsonb(x) order by x.service_at,x.appointment_id),'[]'::jsonb) into v_rows
  from (
    select
      a.id as appointment_id,
      a.start_at as service_at,
      to_char(a.start_at at time zone 'America/Sao_Paulo','DD/MM/YYYY') as date,
      coalesce(c.name,'') as client,
      coalesce(c.cpf_cnpj,'') as cpf_cnpj,
      coalesce(c.address,'') as address,
      coalesce(c.email,'') as email,
      coalesce(a.service_name_snapshot,s.name,'') as service,
      coalesce(a.commercial_value,0)::numeric(12,2) as value,
      coalesce(pm.payment_method,'Não recebido') as payment_method,
      case s.operation_scope when 'BLACKSHEEP' then 'BlackSheep' when 'SABRINA' then 'Sabrina Pierri' else coalesce(s.operation_scope,'') end as operation
    from public.appointments a
    left join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    left join lateral (
      select string_agg(q.label,' + ' order by q.label) as payment_method
      from (
        select distinct case pt.method
          when 'PIX' then 'Pix'
          when 'CASH' then 'Dinheiro'
          when 'CARD' then 'Cartão'
          when 'TRANSFER' then 'Transferência'
          when 'CREDIT' then 'Crédito'
          when 'COURTESY' then 'Cortesia'
          else 'Outro'
        end as label
        from public.payment_transactions pt
        where pt.appointment_id=a.id
          and pt.transaction_type='CHARGE'
          and pt.payment_purpose='CONTRACT'
          and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
          and pt.contract_amount_settled > coalesce((
            select sum(r.contract_amount_settled)
            from public.payment_transactions r
            where r.parent_transaction_id=pt.id
              and r.transaction_type='REFUND'
              and r.status in ('APPROVED','REFUNDED')
          ),0)+0.009
      ) q
    ) pm on true
    where a.status::text='COMPLETED'
      and a.start_at>=v_start and a.start_at<v_end
      and (v_scope is null or s.operation_scope=v_scope)
  ) x;

  return jsonb_build_object(
    'month',to_char(v_month_start,'YYYY-MM'),
    'operation_scope',v_scope,
    'timezone','America/Sao_Paulo',
    'rows',v_rows
  );
end;
$$;

revoke all on function public.service_admin_record_manual_receipt(uuid,text,numeric,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_reverse_manual_receipt(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_edit_manual_receipt(uuid,text,numeric,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_list_receivable_appointments(text,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_finance_month_close(date,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_finance_nfse_export(date,text,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_record_manual_receipt(uuid,text,numeric,timestamptz,text,uuid) to service_role;
grant execute on function public.service_admin_reverse_manual_receipt(uuid,text,uuid) to service_role;
grant execute on function public.service_admin_edit_manual_receipt(uuid,text,numeric,timestamptz,text,uuid) to service_role;
grant execute on function public.service_admin_list_receivable_appointments(text,integer,uuid) to service_role;
grant execute on function public.service_admin_finance_month_close(date,text,uuid) to service_role;
grant execute on function public.service_admin_finance_nfse_export(date,text,uuid) to service_role;
