-- Item D — production test-data classification.
-- Scope: explicit server-side marker + fiscal/admin-finance exclusion.
-- No provider state, business rule, Google Calendar row, customer identity, amount or status is changed.

alter table public.appointments
  add column if not exists is_test boolean not null default false;

alter table public.payment_transactions
  add column if not exists is_test boolean not null default false;

alter table public.customer_balance_movements
  add column if not exists is_test boolean not null default false;

comment on column public.appointments.is_test is
  'True only for explicitly classified operational test appointments. Test appointments are excluded from fiscal/admin finance reporting.';
comment on column public.payment_transactions.is_test is
  'Inherited from appointment. Provider money remains fully traceable even when classified as test.';
comment on column public.customer_balance_movements.is_test is
  'Inherited from appointment when present. Test movements are excluded from finance reporting, not deleted.';

create or replace function public.service_inherit_test_marker_from_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_is_test boolean;
begin
  if new.appointment_id is null then
    new.is_test := false;
    return new;
  end if;

  select a.is_test
    into v_is_test
  from public.appointments a
  where a.id = new.appointment_id;

  if found then
    new.is_test := coalesce(v_is_test,false);
  end if;
  return new;
end;
$$;

revoke all on function public.service_inherit_test_marker_from_appointment() from public, anon, authenticated, service_role;

drop trigger if exists trg_payment_transactions_inherit_test_marker on public.payment_transactions;
create trigger trg_payment_transactions_inherit_test_marker
before insert or update of appointment_id, is_test on public.payment_transactions
for each row execute function public.service_inherit_test_marker_from_appointment();

drop trigger if exists trg_customer_balance_movements_inherit_test_marker on public.customer_balance_movements;
create trigger trg_customer_balance_movements_inherit_test_marker
before insert or update of appointment_id, is_test on public.customer_balance_movements
for each row execute function public.service_inherit_test_marker_from_appointment();

create or replace function public.service_propagate_appointment_test_marker()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.is_test is distinct from new.is_test then
    update public.payment_transactions
       set is_test = new.is_test
     where appointment_id = new.id
       and is_test is distinct from new.is_test;

    update public.customer_balance_movements
       set is_test = new.is_test
     where appointment_id = new.id
       and is_test is distinct from new.is_test;
  end if;
  return null;
end;
$$;

revoke all on function public.service_propagate_appointment_test_marker() from public, anon, authenticated, service_role;

drop trigger if exists trg_appointments_propagate_test_marker on public.appointments;
create trigger trg_appointments_propagate_test_marker
after update of is_test on public.appointments
for each row execute function public.service_propagate_appointment_test_marker();

-- Fail closed if the audited pre-opening set changed before this migration is applied.
do $$
declare
  v_expected integer := 10;
  v_found integer;
begin
  select count(*)::integer
    into v_found
  from public.appointments
  where id = any(array[
    'bb9d9d3e-6a51-4d43-86c5-9ab925da9dc4'::uuid,
    '92d350d7-ea63-40ea-aae0-e2431ae3e341'::uuid,
    '2da971ae-66f8-4bf8-8599-24a014c2bfa2'::uuid,
    'b52f0103-5815-4f5c-9900-ca09fff86a96'::uuid,
    '69f1ee55-b56f-4881-bc92-9cfe1c4e77fb'::uuid,
    '69b0e54e-2b6d-4506-a89a-1ed96ab03452'::uuid,
    '99d3e40b-4470-4eab-a541-6b90dbbbe31f'::uuid,
    '57186cdb-9c2b-45de-ac03-ee55fdbfff05'::uuid,
    'd052a506-39e8-4cad-905f-b14fb87dc866'::uuid,
    '7439ea01-28fb-4a73-8b2a-dca4880b5409'::uuid
  ]);

  if v_found <> v_expected then
    raise exception using errcode='P0001', message='ITEM_D_TEST_APPOINTMENT_SET_MISMATCH';
  end if;

  update public.appointments
     set is_test = true
   where id = any(array[
    'bb9d9d3e-6a51-4d43-86c5-9ab925da9dc4'::uuid,
    '92d350d7-ea63-40ea-aae0-e2431ae3e341'::uuid,
    '2da971ae-66f8-4bf8-8599-24a014c2bfa2'::uuid,
    'b52f0103-5815-4f5c-9900-ca09fff86a96'::uuid,
    '69f1ee55-b56f-4881-bc92-9cfe1c4e77fb'::uuid,
    '69b0e54e-2b6d-4506-a89a-1ed96ab03452'::uuid,
    '99d3e40b-4470-4eab-a541-6b90dbbbe31f'::uuid,
    '57186cdb-9c2b-45de-ac03-ee55fdbfff05'::uuid,
    'd052a506-39e8-4cad-905f-b14fb87dc866'::uuid,
    '7439ea01-28fb-4a73-8b2a-dca4880b5409'::uuid
  ]);
end;
$$;

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
      round(greatest(coalesce(a.commercial_value,0)-public.appointment_contract_coverage_amount(a.id),0),2)::numeric(12,2) outstanding,
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
          and not pt.is_test
          and pt.transaction_type='CHARGE'
          and pt.payment_purpose='CONTRACT'
          and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
        union
        select 'Saldo do cliente'
        where exists(
          select 1
          from public.customer_balance_movements cbm
          where cbm.appointment_id=a.id
            and not cbm.is_test
            and cbm.movement_type='APPLY_TO_APPOINTMENT'
            and cbm.direction='DEBIT'
        )
      ) q
    ) pm on true
    where not a.is_test
      and a.status in('COMPLETED','NO_SHOW')
      and a.start_at>=v_start
      and a.start_at<v_end
      and (v_scope is null or s.operation_scope=v_scope)
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
  where not a.is_test and a.status in('COMPLETED','NO_SHOW') and a.start_at>=v_start and a.start_at<v_end and (v_scope is null or s.operation_scope=v_scope);

  v_net_settled:=round(greatest(v_gross_settled-v_contract_refunded,0),2);
  v_outstanding:=round(greatest(v_contracted-v_net_settled,0),2);

  select coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='CHARGE' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),
         coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='REFUND' and pt.status in('APPROVED','REFUNDED')),0)::numeric(12,2)
  into v_cash_received,v_cash_refunded
  from public.payment_transactions pt join public.appointments a on a.id=pt.appointment_id join public.services s on s.id=a.service_id
  where not pt.is_test and not a.is_test
    and coalesce(pt.paid_at,pt.created_at)>=v_start and coalesce(pt.paid_at,pt.created_at)<v_end
    and (v_scope is null or s.operation_scope=v_scope);

  if v_scope is null then
    select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2)
      into v_balance_open
    from public.customer_balance_movements cbm
    where cbm.direction='CREDIT' and not cbm.is_test and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>now();
  else
    select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2)
    into v_balance_open
    from public.customer_balance_movements cbm join public.appointments a on a.id=cbm.appointment_id join public.services s on s.id=a.service_id
    where cbm.direction='CREDIT' and not cbm.is_test and not a.is_test
      and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>now() and s.operation_scope=v_scope;
  end if;

  select coalesce(sum(cbm.amount) filter(where cbm.direction='CREDIT'),0)::numeric(12,2),coalesce(sum(cbm.amount) filter(where cbm.direction='DEBIT'),0)::numeric(12,2)
  into v_balance_credited,v_balance_applied
  from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where not cbm.is_test and (a.id is null or not a.is_test)
    and cbm.created_at>=v_start and cbm.created_at<v_end and (v_scope is null or s.operation_scope=v_scope);

  select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2)
  into v_balance_expired
  from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where cbm.direction='CREDIT' and not cbm.is_test and (a.id is null or not a.is_test)
    and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>=v_start and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')<v_end
    and (v_scope is null or s.operation_scope=v_scope);

  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'service_count',v_count,'revenue',round(v_contracted,2),
    'services',jsonb_build_object('service_count',v_count,'contracted',round(v_contracted,2),'statuses',jsonb_build_array('COMPLETED','NO_SHOW')),
    'contract',jsonb_build_object('gross_settled',round(v_gross_settled,2),'refunded',round(v_contract_refunded,2),'net_settled',v_net_settled,'outstanding',v_outstanding),
    'cash',jsonb_build_object('received',round(v_cash_received,2),'refunded',round(v_cash_refunded,2),'net',round(v_cash_received-v_cash_refunded,2)),
    'customer_balance',jsonb_build_object('open_liability',round(v_balance_open,2),'credited_in_month',round(v_balance_credited,2),'applied_in_month',round(v_balance_applied,2),'expired_in_month',round(v_balance_expired,2),'validity_months',12,'accounting_classification','LIABILITY_NOT_REVENUE'),
    'range',jsonb_build_object('start_at',v_start,'end_at',v_end),'timezone','America/Sao_Paulo');
end;
$$;

create or replace function public.service_admin_finance_pending_refunds(p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001', message='FINANCE_OPERATION_SCOPE_INVALID'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'policy_action_id', pa.id,'appointment_id', a.id,'public_code', a.public_code,'service_at', a.start_at,'operation_scope', s.operation_scope,
    'customer_id', c.id,'customer_name', c.name,'service_name', coalesce(a.service_name_snapshot,s.name),
    'target_refund', coalesce((p.plan->>'target_cash_amount')::numeric,0),'recorded_refund', coalesce((p.plan->>'recorded_refund_cash')::numeric,0),
    'remaining_refund', coalesce((p.plan->>'remaining_refund_cash')::numeric,0),'gateway_available', coalesce((p.plan->>'mercado_pago_available_cash')::numeric,0),
    'gateway_refund_amount', greatest(coalesce((p.plan->>'remaining_refund_cash')::numeric,0)-coalesce((p.plan->>'manual_refund_cash')::numeric,0),0),
    'manual_refund_amount', coalesce((p.plan->>'manual_refund_cash')::numeric,0),'status', pa.status
  ) order by a.start_at desc),'[]'::jsonb)
  into v_rows
  from public.appointment_policy_actions pa
  join public.appointments a on a.id=pa.appointment_id
  join public.services s on s.id=a.service_id
  left join public.customers c on c.id=a.primary_customer_id
  cross join lateral (select public.service_get_cancellation_refund_plan(pa.id) as plan) p
  where not a.is_test
    and pa.action_type='CANCEL' and pa.settlement_choice='REFUND' and pa.status='PENDING_REFUND'
    and coalesce((p.plan->>'remaining_refund_cash')::numeric,0)>0.009
    and (v_scope is null or s.operation_scope=v_scope);

  return jsonb_build_object('operation_scope',v_scope,'refunds',v_rows);
end;
$$;

create or replace function public.service_admin_list_manual_receipts(p_month date, p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
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
    select pt.id transaction_id,pt.appointment_id,pt.method,pt.status,pt.contract_amount_settled::numeric(12,2) amount,pt.paid_at,pt.notes,pt.created_by_admin_id,
      au.display_name registered_by,a.public_code,a.start_at appointment_start_at,coalesce(a.service_name_snapshot,s.name,'Serviço') service_name,s.operation_scope,c.id customer_id,c.name customer_name,
      not exists(select 1 from public.payment_transactions r where r.parent_transaction_id=pt.id and not r.is_test and r.transaction_type='REFUND' and r.status in('APPROVED','REFUNDED')) and pt.status='APPROVED' editable
    from public.payment_transactions pt
    join public.appointments a on a.id=pt.appointment_id
    join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    left join public.admin_users au on au.id=pt.created_by_admin_id
    where not pt.is_test and not a.is_test
      and pt.provider='MANUAL' and pt.transaction_type='CHARGE' and pt.payment_purpose='CONTRACT' and pt.method in('CASH','PIX')
      and coalesce(pt.paid_at,pt.created_at)>=v_start and coalesce(pt.paid_at,pt.created_at)<v_end
      and (v_scope is null or s.operation_scope=v_scope)
  ) x;

  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'timezone','America/Sao_Paulo','receipts',v_rows);
end;
$$;

create or replace function public.service_admin_list_receivable_appointments_page(p_search text, p_operation_scope text, p_cursor_start_at timestamptz, p_cursor_appointment_id uuid, p_limit integer, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_search text := nullif(lower(btrim(coalesce(p_search,''))),'');
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_limit integer := least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb; v_has_more boolean; v_next_cursor jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then raise exception 'FINANCE_OPERATION_SCOPE_INVALID'; end if;
  if (p_cursor_start_at is null) <> (p_cursor_appointment_id is null) then raise exception 'FINANCE_CURSOR_INVALID'; end if;

  with raw as (
    select a.id appointment_id,a.public_code,a.start_at,a.status::text status,a.financial_status::text financial_status,
      coalesce(a.service_name_snapshot,s.name,'Serviço') service_name,s.operation_scope,c.id customer_id,c.name customer_name,c.cpf_cnpj,c.email,
      coalesce(a.commercial_value,0)::numeric(12,2) commercial_value,public.appointment_net_contract_settled_amount(a.id)::numeric(12,2) net_paid,
      round(greatest(coalesce(a.commercial_value,0)-public.appointment_net_contract_settled_amount(a.id),0),2)::numeric(12,2) remaining_due
    from public.appointments a
    join public.customers c on c.id=a.primary_customer_id
    left join public.services s on s.id=a.service_id
    where not a.is_test
      and coalesce(a.commercial_value,0)>0 and a.status::text not in('CANCELLED','EXPIRED')
      and public.appointment_net_contract_settled_amount(a.id)<coalesce(a.commercial_value,0)-0.009
      and (v_scope is null or s.operation_scope=v_scope)
      and (p_cursor_start_at is null or a.start_at<p_cursor_start_at or (a.start_at=p_cursor_start_at and a.id<p_cursor_appointment_id))
      and (v_search is null or lower(coalesce(a.public_code,'')) like '%'||v_search||'%' or lower(c.name) like '%'||v_search||'%' or lower(coalesce(c.email,'')) like '%'||v_search||'%' or lower(coalesce(c.phone,'')) like '%'||v_search||'%' or regexp_replace(coalesce(c.cpf_cnpj,''),'[^0-9]','','g') like '%'||regexp_replace(v_search,'[^0-9]','','g')||'%')
    order by a.start_at desc,a.id desc
    limit v_limit+1
  ), numbered as (
    select raw.*,row_number() over(order by raw.start_at desc,raw.appointment_id desc) rn from raw
  )
  select coalesce(jsonb_agg((to_jsonb(n)-'rn') order by n.start_at desc,n.appointment_id desc) filter(where n.rn<=v_limit),'[]'::jsonb),count(*)>v_limit,
    case when count(*)>v_limit then (select jsonb_build_object('start_at',n2.start_at,'appointment_id',n2.appointment_id) from numbered n2 where n2.rn=v_limit) else null end
  into v_rows,v_has_more,v_next_cursor from numbered n;

  return jsonb_build_object('appointments',v_rows,'has_more',v_has_more,'next_cursor',v_next_cursor);
end;
$$;

create or replace function public.service_finance_customer_balance_report(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_open numeric(12,2); v_credits numeric(12,2); v_applied numeric(12,2); v_refunds numeric(12,2); v_expired numeric(12,2);
begin
  if p_from is null or p_to is null or p_to<=p_from then raise exception using errcode='P0001',message='INVALID_REPORT_PERIOD'; end if;

  select coalesce(sum(greatest(c.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=c.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2)
    into v_open
  from public.customer_balance_movements c
  where c.direction='CREDIT' and not c.is_test and coalesce(c.expires_at,c.created_at+interval '12 months')>now();

  select coalesce(sum(amount) filter(where movement_type='CREDIT_FROM_RETURN'),0)::numeric(12,2),coalesce(sum(amount) filter(where movement_type='APPLY_TO_APPOINTMENT'),0)::numeric(12,2)
    into v_credits,v_applied
  from public.customer_balance_movements
  where not is_test and created_at>=p_from and created_at<p_to;

  select coalesce(sum(amount),0)::numeric(12,2)
    into v_refunds
  from public.customer_balance_refund_requests
  where requested_at>=p_from and requested_at<p_to;

  select coalesce(sum(greatest(c.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=c.id and d.direction='DEBIT' and not d.is_test),0),0)),0)::numeric(12,2)
    into v_expired
  from public.customer_balance_movements c
  where c.direction='CREDIT' and not c.is_test
    and coalesce(c.expires_at,c.created_at+interval '12 months')>=p_from
    and coalesce(c.expires_at,c.created_at+interval '12 months')<p_to;

  return jsonb_build_object('period_from',p_from,'period_to',p_to,'customer_balance_open_liability',v_open,'balance_credited_in_period',v_credits,'balance_applied_to_reservations_in_period',v_applied,'balance_refund_requests_in_period',v_refunds,'balance_expired_in_period',v_expired,'validity_months',12,'accounting_classification','LIABILITY_NOT_REVENUE');
end;
$$;
