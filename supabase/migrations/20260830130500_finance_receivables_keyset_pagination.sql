create or replace function public.service_admin_list_receivable_appointments_page(
  p_search text,
  p_operation_scope text,
  p_cursor_start_at timestamptz,
  p_cursor_appointment_id uuid,
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
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_limit integer := least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb;
  v_has_more boolean;
  v_next_cursor jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception 'FINANCE_OPERATION_SCOPE_INVALID';
  end if;
  if (p_cursor_start_at is null) <> (p_cursor_appointment_id is null) then
    raise exception 'FINANCE_CURSOR_INVALID';
  end if;

  with raw as (
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
      and (v_scope is null or s.operation_scope=v_scope)
      and (
        p_cursor_start_at is null
        or a.start_at < p_cursor_start_at
        or (a.start_at = p_cursor_start_at and a.id < p_cursor_appointment_id)
      )
      and (
        v_search is null
        or lower(coalesce(a.public_code,'')) like '%'||v_search||'%'
        or lower(c.name) like '%'||v_search||'%'
        or lower(coalesce(c.email,'')) like '%'||v_search||'%'
        or lower(coalesce(c.phone,'')) like '%'||v_search||'%'
        or regexp_replace(coalesce(c.cpf_cnpj,''),'[^0-9]','','g') like '%'||regexp_replace(v_search,'[^0-9]','','g')||'%'
      )
    order by a.start_at desc,a.id desc
    limit v_limit+1
  ), numbered as (
    select raw.*,row_number() over(order by raw.start_at desc,raw.appointment_id desc) as rn
    from raw
  )
  select
    coalesce(
      jsonb_agg((to_jsonb(n)-'rn') order by n.start_at desc,n.appointment_id desc)
        filter (where n.rn<=v_limit),
      '[]'::jsonb
    ),
    count(*)>v_limit,
    case when count(*)>v_limit then (
      select jsonb_build_object('start_at',n2.start_at,'appointment_id',n2.appointment_id)
      from numbered n2
      where n2.rn=v_limit
    ) else null end
  into v_rows,v_has_more,v_next_cursor
  from numbered n;

  return jsonb_build_object(
    'appointments',v_rows,
    'has_more',v_has_more,
    'next_cursor',v_next_cursor
  );
end;
$$;

revoke all on function public.service_admin_list_receivable_appointments_page(text,text,timestamptz,uuid,integer,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_list_receivable_appointments_page(text,text,timestamptz,uuid,integer,uuid) to service_role;
