create or replace function public.service_admin_list_customers_page(
  p_search text,
  p_limit integer,
  p_offset integer,
  p_operation_scope text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_operation_scope text := upper(btrim(coalesce(p_operation_scope, 'ALL')));
  v_total integer;
  v_customers jsonb;
begin
  if v_operation_scope not in ('ALL', 'BLACKSHEEP', 'SABRINA') then
    raise exception 'CUSTOMER_OPERATION_SCOPE_INVALID';
  end if;

  select count(*)::integer
  into v_total
  from public.customers c
  where (
    v_search is null
    or lower(c.name) like '%' || lower(v_search) || '%'
    or lower(coalesce(c.legal_name, '')) like '%' || lower(v_search) || '%'
    or lower(coalesce(c.email, '')) like '%' || lower(v_search) || '%'
    or coalesce(c.phone, '') like '%' || v_search || '%'
    or coalesce(c.cpf_cnpj, '') like '%' || v_search || '%'
    or lower(coalesce(c.address, '')) like '%' || lower(v_search) || '%'
  )
  and (
    v_operation_scope = 'ALL'
    or exists (
      select 1
      from public.appointments a
      join public.services s on s.id = a.service_id
      where a.primary_customer_id = c.id
        and a.deleted_at is null
        and a.status <> 'DRAFT'
        and s.operation_scope = v_operation_scope
    )
    or exists (
      select 1
      from public.appointment_participants ap
      join public.appointments a on a.id = ap.appointment_id
      join public.services s on s.id = a.service_id
      where ap.customer_id = c.id
        and a.deleted_at is null
        and a.status <> 'DRAFT'
        and s.operation_scope = v_operation_scope
    )
  );

  select coalesce(jsonb_agg(row_data order by sort_name, sort_id), '[]'::jsonb)
  into v_customers
  from (
    select
      c.name as sort_name,
      c.id as sort_id,
      jsonb_build_object(
        'id', c.id,
        'customer_type', c.customer_type,
        'name', c.name,
        'legal_name', c.legal_name,
        'cpf_cnpj', c.cpf_cnpj,
        'email', c.email,
        'phone', c.phone,
        'address', c.address,
        'birth_date', c.birth_date,
        'anonymized_at', c.anonymized_at,
        'commercial_terms', case when t.customer_id is null then null else jsonb_build_object(
          'can_prebook', t.can_prebook,
          'prebook_hold_minutes', t.prebook_hold_minutes,
          'max_active_prebooks', t.max_active_prebooks,
          'requires_manual_confirmation', t.requires_manual_confirmation,
          'billing_mode', t.billing_mode,
          'invoice_due_days', t.invoice_due_days,
          'is_active', t.is_active
        ) end
      ) as row_data
    from public.customers c
    left join public.customer_commercial_terms t on t.customer_id = c.id
    where (
      v_search is null
      or lower(c.name) like '%' || lower(v_search) || '%'
      or lower(coalesce(c.legal_name, '')) like '%' || lower(v_search) || '%'
      or lower(coalesce(c.email, '')) like '%' || lower(v_search) || '%'
      or coalesce(c.phone, '') like '%' || v_search || '%'
      or coalesce(c.cpf_cnpj, '') like '%' || v_search || '%'
      or lower(coalesce(c.address, '')) like '%' || lower(v_search) || '%'
    )
    and (
      v_operation_scope = 'ALL'
      or exists (
        select 1
        from public.appointments a
        join public.services s on s.id = a.service_id
        where a.primary_customer_id = c.id
          and a.deleted_at is null
          and a.status <> 'DRAFT'
          and s.operation_scope = v_operation_scope
      )
      or exists (
        select 1
        from public.appointment_participants ap
        join public.appointments a on a.id = ap.appointment_id
        join public.services s on s.id = a.service_id
        where ap.customer_id = c.id
          and a.deleted_at is null
          and a.status <> 'DRAFT'
          and s.operation_scope = v_operation_scope
      )
    )
    order by c.name, c.id
    limit v_limit offset v_offset
  ) page_rows;

  return jsonb_build_object(
    'customers', v_customers,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', (v_offset + v_limit) < v_total
  );
end;
$$;

create or replace function public.service_admin_list_customers_page(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.service_admin_list_customers_page(
    p_search,
    p_limit,
    p_offset,
    'ALL'::text
  );
$$;

revoke all on function public.service_admin_list_customers_page(text, integer, integer, text) from public;
revoke all on function public.service_admin_list_customers_page(text, integer, integer, text) from anon;
revoke all on function public.service_admin_list_customers_page(text, integer, integer, text) from authenticated;
grant execute on function public.service_admin_list_customers_page(text, integer, integer, text) to service_role;

revoke all on function public.service_admin_list_customers_page(text, integer, integer) from public;
revoke all on function public.service_admin_list_customers_page(text, integer, integer) from anon;
revoke all on function public.service_admin_list_customers_page(text, integer, integer) from authenticated;
grant execute on function public.service_admin_list_customers_page(text, integer, integer) to service_role;
