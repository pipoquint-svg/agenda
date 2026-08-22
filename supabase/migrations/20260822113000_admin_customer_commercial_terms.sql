-- Administrative read/write model for customer commercial terms.
-- Keeps special rules (pre-booking, invoicing) in the Agenda backend and audits every change.

create or replace function public.service_admin_list_customers(
  p_search text default null,
  p_limit integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customers',
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'customer_type', c.customer_type,
        'name', c.name,
        'legal_name', c.legal_name,
        'cpf_cnpj', c.cpf_cnpj,
        'email', c.email,
        'phone', c.phone,
        'commercial_terms', case when t.customer_id is null then null else jsonb_build_object(
          'can_prebook', t.can_prebook,
          'prebook_hold_minutes', t.prebook_hold_minutes,
          'max_active_prebooks', t.max_active_prebooks,
          'requires_manual_confirmation', t.requires_manual_confirmation,
          'billing_mode', t.billing_mode,
          'invoice_due_days', t.invoice_due_days,
          'is_active', t.is_active
        ) end
      ) order by c.name, c.id
    ), '[]'::jsonb)
  )
  from (
    select *
    from public.customers c0
    where p_search is null
       or btrim(p_search) = ''
       or lower(c0.name) like '%' || lower(btrim(p_search)) || '%'
       or lower(coalesce(c0.legal_name, '')) like '%' || lower(btrim(p_search)) || '%'
       or lower(coalesce(c0.email, '')) like '%' || lower(btrim(p_search)) || '%'
       or coalesce(c0.phone, '') like '%' || btrim(p_search) || '%'
       or coalesce(c0.cpf_cnpj, '') like '%' || btrim(p_search) || '%'
    order by c0.name, c0.id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) c
  left join public.customer_commercial_terms t on t.customer_id = c.id;
$$;

create or replace function public.service_admin_get_customer_commercial_profile(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customer', jsonb_build_object(
      'id', c.id,
      'customer_type', c.customer_type,
      'name', c.name,
      'legal_name', c.legal_name,
      'cpf_cnpj', c.cpf_cnpj,
      'email', c.email,
      'phone', c.phone,
      'notes', c.notes
    ),
    'terms', case when t.customer_id is null then null else jsonb_build_object(
      'can_prebook', t.can_prebook,
      'prebook_hold_minutes', t.prebook_hold_minutes,
      'max_active_prebooks', t.max_active_prebooks,
      'requires_manual_confirmation', t.requires_manual_confirmation,
      'billing_mode', t.billing_mode,
      'invoice_due_days', t.invoice_due_days,
      'is_active', t.is_active
    ) end,
    'authorized_services', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug) order by s.sort_order, s.name)
      from public.customer_prebook_authorized_services cas
      join public.services s on s.id = cas.service_id
      where cas.customer_id = c.id
    ), '[]'::jsonb),
    'active_pre_reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pr.id,
        'service_id', pr.service_id,
        'service_name', s.name,
        'start_at', pr.start_at,
        'end_at', pr.end_at,
        'expires_at', pr.expires_at,
        'status', pr.status,
        'converted_appointment_id', pr.converted_appointment_id
      ) order by pr.start_at)
      from public.pre_reservations pr
      join public.services s on s.id = pr.service_id
      where pr.customer_id = c.id
        and pr.status = 'ACTIVE'
    ), '[]'::jsonb)
  )
  from public.customers c
  left join public.customer_commercial_terms t on t.customer_id = c.id
  where c.id = p_customer_id;
$$;

create or replace function public.service_admin_set_customer_commercial_terms(
  p_customer_id uuid,
  p_can_prebook boolean,
  p_prebook_hold_minutes integer,
  p_max_active_prebooks integer,
  p_requires_manual_confirmation boolean,
  p_billing_mode text,
  p_invoice_due_days integer,
  p_is_active boolean,
  p_authorized_service_ids uuid[],
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_mode text := upper(btrim(coalesce(p_billing_mode, '')));
begin
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  if coalesce(p_prebook_hold_minutes, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'PREBOOK_HOLD_MINUTES_INVALID';
  end if;
  if coalesce(p_max_active_prebooks, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'MAX_ACTIVE_PREBOOKS_INVALID';
  end if;
  if v_mode not in ('CHECKOUT','INVOICE') then
    raise exception using errcode = 'P0001', message = 'BILLING_MODE_INVALID';
  end if;
  if v_mode = 'INVOICE' and (p_invoice_due_days is null or p_invoice_due_days < 0) then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_INVALID';
  end if;
  if v_mode = 'CHECKOUT' and p_invoice_due_days is not null then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_NOT_ALLOWED';
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_before;

  insert into public.customer_commercial_terms(
    customer_id, can_prebook, prebook_hold_minutes, max_active_prebooks,
    requires_manual_confirmation, billing_mode, invoice_due_days, is_active, updated_at
  ) values (
    p_customer_id, coalesce(p_can_prebook, false), p_prebook_hold_minutes, p_max_active_prebooks,
    coalesce(p_requires_manual_confirmation, true), v_mode,
    case when v_mode = 'INVOICE' then p_invoice_due_days else null end,
    coalesce(p_is_active, true), now()
  )
  on conflict (customer_id) do update set
    can_prebook = excluded.can_prebook,
    prebook_hold_minutes = excluded.prebook_hold_minutes,
    max_active_prebooks = excluded.max_active_prebooks,
    requires_manual_confirmation = excluded.requires_manual_confirmation,
    billing_mode = excluded.billing_mode,
    invoice_due_days = excluded.invoice_due_days,
    is_active = excluded.is_active,
    updated_at = now();

  delete from public.customer_prebook_authorized_services where customer_id = p_customer_id;

  if coalesce(array_length(p_authorized_service_ids, 1), 0) > 0 then
    if exists (
      select 1 from unnest(p_authorized_service_ids) x(service_id)
      left join public.services s on s.id = x.service_id and s.is_active
      where s.id is null
    ) then
      raise exception using errcode = 'P0001', message = 'AUTHORIZED_SERVICE_INVALID';
    end if;

    insert into public.customer_prebook_authorized_services(customer_id, service_id)
    select p_customer_id, service_id
    from unnest(p_authorized_service_ids) x(service_id)
    on conflict do nothing;
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (p_admin_id, 'CUSTOMER', p_customer_id, 'COMMERCIAL_TERMS_CHANGED', v_before, v_after, 'ADMIN');

  return v_after;
end;
$$;

revoke all on function public.service_admin_list_customers(text,integer) from public, anon, authenticated;
grant execute on function public.service_admin_list_customers(text,integer) to service_role;
revoke all on function public.service_admin_get_customer_commercial_profile(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_get_customer_commercial_profile(uuid) to service_role;
revoke all on function public.service_admin_set_customer_commercial_terms(uuid,boolean,integer,integer,boolean,text,integer,boolean,uuid[],uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_customer_commercial_terms(uuid,boolean,integer,integer,boolean,text,integer,boolean,uuid[],uuid) to service_role;
