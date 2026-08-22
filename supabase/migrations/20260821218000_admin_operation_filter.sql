-- Administrative operation/brand view is derived from booking page membership.
-- Services remain the source of commercial rules; no duplicate brand flag is stored on appointments.

create or replace function public.service_admin_appointment_brand_keys(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(x.brand_key order by x.brand_key), '[]'::jsonb)
  from (
    select distinct bp.brand_key
    from public.appointments a
    join public.booking_page_services bps on bps.service_id = a.service_id and bps.is_active
    join public.booking_pages bp on bp.id = bps.booking_page_id and bp.is_active
    where a.id = p_appointment_id
  ) x;
$$;

create or replace function public.service_admin_list_agenda_v2(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_brand_key text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_brand text := nullif(upper(btrim(coalesce(p_brand_key, ''))), '');
  v_appointments jsonb := '[]'::jsonb;
  v_item jsonb;
  v_id uuid;
  v_brand_keys jsonb;
begin
  if v_brand is not null and v_brand not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode='P0001', message='ADMIN_BRAND_FILTER_INVALID';
  end if;

  v_base := public.service_admin_list_agenda(p_start_at, p_end_at);

  for v_item in select value from jsonb_array_elements(coalesce(v_base->'appointments','[]'::jsonb))
  loop
    v_id := (v_item->>'id')::uuid;
    v_brand_keys := public.service_admin_appointment_brand_keys(v_id);

    if v_brand is null or v_brand_keys ? v_brand then
      v_appointments := v_appointments || jsonb_build_array(v_item || jsonb_build_object('brand_keys', v_brand_keys));
    end if;
  end loop;

  return jsonb_set(v_base, '{appointments}', v_appointments, true)
    || jsonb_build_object('brand_filter', v_brand);
end;
$$;

create or replace function public.service_admin_get_appointment_v2(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_brand_keys jsonb;
begin
  v_base := public.service_admin_get_appointment(p_appointment_id);
  v_brand_keys := public.service_admin_appointment_brand_keys(p_appointment_id);
  return jsonb_set(v_base, '{appointment,brand_keys}', v_brand_keys, true);
end;
$$;

revoke all on function public.service_admin_appointment_brand_keys(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_list_agenda_v2(timestamptz,timestamptz,text) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment_v2(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_appointment_brand_keys(uuid) to service_role;
grant execute on function public.service_admin_list_agenda_v2(timestamptz,timestamptz,text) to service_role;
grant execute on function public.service_admin_get_appointment_v2(uuid) to service_role;
