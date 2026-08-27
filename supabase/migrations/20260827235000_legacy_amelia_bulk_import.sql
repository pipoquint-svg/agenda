-- Bulk helper for history-only Amelia recovery imports.
-- Each source row must already carry a stable unique amelia_booking_id.
-- Customer matching is best-effort against the master customer table and does not
-- create appointments, payments, holds, resources, notifications or Google events.

create or replace function public.service_import_legacy_amelia_bookings_batch(
  p_import_batch_id uuid,
  p_bookings jsonb
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_booking jsonb;
  v_booking_row_id uuid;
  v_customer_id uuid;
  v_email text;
  v_phone text;
  v_processed integer := 0;
  v_matched integer := 0;
begin
  if p_bookings is null or jsonb_typeof(p_bookings) <> 'array' then
    raise exception using errcode='P0001', message='AMELIA_IMPORT_BOOKINGS_ARRAY_REQUIRED';
  end if;

  if not exists (
    select 1 from public.legacy_amelia_import_batches
    where id = p_import_batch_id and status = 'OPEN'
  ) then
    raise exception using errcode='P0001', message='AMELIA_IMPORT_BATCH_NOT_OPEN';
  end if;

  for v_booking in select value from jsonb_array_elements(p_bookings)
  loop
    v_booking_row_id := public.upsert_legacy_amelia_booking(p_import_batch_id, v_booking);
    v_processed := v_processed + 1;

    v_email := nullif(lower(btrim(v_booking->>'customer_email')), '');
    v_phone := nullif(regexp_replace(coalesce(v_booking->>'customer_phone',''), '\D', '', 'g'), '');
    v_customer_id := null;

    select c.id into v_customer_id
    from public.customers c
    where (v_email is not null and lower(coalesce(c.email,'')) = v_email)
       or (
         v_phone is not null
         and length(v_phone) >= 8
         and right(regexp_replace(coalesce(c.phone,''), '\D', '', 'g'), 11) = right(v_phone, 11)
       )
    order by case when v_email is not null and lower(coalesce(c.email,'')) = v_email then 0 else 1 end,
             c.created_at
    limit 1;

    if v_customer_id is not null then
      update public.legacy_amelia_bookings
      set matched_customer_id = v_customer_id
      where id = v_booking_row_id;
      v_matched := v_matched + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'processed', v_processed,
    'matched_customers', v_matched
  );
end;
$$;

revoke all on function public.service_import_legacy_amelia_bookings_batch(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.service_import_legacy_amelia_bookings_batch(uuid,jsonb) to service_role;

comment on function public.service_import_legacy_amelia_bookings_batch(uuid,jsonb) is
  'Service-role-only bulk importer for HISTORY_ONLY Amelia records. Never creates native appointments, payments or external side effects.';
