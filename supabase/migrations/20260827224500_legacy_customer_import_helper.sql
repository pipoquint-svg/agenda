-- Service-role-only helper for traced legacy customer imports.
-- It merges by normalized e-mail or the last 11 phone digits and records every
-- source row in legacy_customer_sources. It never creates appointments/payments.

create or replace function public.service_import_legacy_customer_rows(
  p_batch_id uuid,
  p_source text,
  p_rows jsonb
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_row jsonb;
  v_customer uuid;
  v_email text;
  v_phone text;
  v_source_key text;
  v_created integer := 0;
  v_matched integer := 0;
  v_processed integer := 0;
begin
  if p_batch_id is null or not exists (select 1 from public.legacy_import_batches where id = p_batch_id) then
    raise exception using errcode = 'P0001', message = 'LEGACY_IMPORT_BATCH_NOT_FOUND';
  end if;
  if nullif(btrim(p_source), '') is null then
    raise exception using errcode = 'P0001', message = 'LEGACY_IMPORT_SOURCE_REQUIRED';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode = 'P0001', message = 'LEGACY_IMPORT_ROWS_INVALID';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_processed := v_processed + 1;
    v_email := nullif(lower(btrim(v_row->>'email')), '');
    v_phone := nullif(regexp_replace(coalesce(v_row->>'phone', ''), '\D', '', 'g'), '');
    v_source_key := coalesce(nullif(v_row->>'source_key', ''), 'row:' || coalesce(v_row->>'row', v_processed::text));
    v_customer := null;

    select c.id into v_customer
    from public.customers c
    where (v_email is not null and lower(c.email) = v_email)
       or (v_phone is not null and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 11) = right(v_phone, 11))
    order by case when v_email is not null and lower(c.email) = v_email then 0 else 1 end, c.created_at
    limit 1;

    if v_customer is null then
      insert into public.customers (
        customer_type, name, email, phone, birth_date, notes
      ) values (
        case when upper(coalesce(v_row->>'customer_type', 'PERSON')) = 'BUSINESS' then 'BUSINESS' else 'PERSON' end,
        coalesce(nullif(btrim(v_row->>'name'), ''), 'Cliente legado'),
        v_email,
        nullif(v_row->>'phone', ''),
        nullif(v_row->>'birth_date', '')::date,
        concat_ws(' · ',
          'Origem: ' || p_source,
          case when coalesce((v_row->>'total_reservations')::integer, 0) > 0
            then 'Reservas no legado: ' || (v_row->>'total_reservations') else null end,
          case when nullif(v_row->>'last_booking', '') is not null
            then 'Última reserva no export: ' || (v_row->>'last_booking') else null end
        )
      ) returning id into v_customer;
      v_created := v_created + 1;
    else
      update public.customers c
      set name = case when btrim(coalesce(c.name, '')) = '' then coalesce(nullif(btrim(v_row->>'name'), ''), c.name) else c.name end,
          email = coalesce(c.email, v_email),
          phone = coalesce(c.phone, nullif(v_row->>'phone', '')),
          birth_date = coalesce(c.birth_date, nullif(v_row->>'birth_date', '')::date),
          updated_at = now()
      where c.id = v_customer;
      v_matched := v_matched + 1;
    end if;

    insert into public.legacy_customer_sources (
      batch_id, source, source_key, source_row_number, customer_id,
      match_method, match_confidence, raw_snapshot
    ) values (
      p_batch_id,
      p_source,
      v_source_key,
      nullif(v_row->>'row', '')::integer,
      v_customer,
      case when v_email is not null and v_phone is not null then 'EMAIL_PHONE'
           when v_email is not null then 'EMAIL'
           when v_phone is not null then 'PHONE'
           else 'CREATED' end,
      case when v_email is not null or v_phone is not null then 'HIGH' else 'MEDIUM' end,
      v_row
    )
    on conflict (source, source_key) do update
      set batch_id = excluded.batch_id,
          customer_id = excluded.customer_id,
          match_method = excluded.match_method,
          match_confidence = excluded.match_confidence,
          raw_snapshot = excluded.raw_snapshot,
          updated_at = now();
  end loop;

  return jsonb_build_object('processed', v_processed, 'created', v_created, 'matched', v_matched);
end;
$$;

revoke all on function public.service_import_legacy_customer_rows(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.service_import_legacy_customer_rows(uuid,text,jsonb) to service_role;

comment on function public.service_import_legacy_customer_rows(uuid,text,jsonb) is
  'Service-role-only traced importer for legacy customer master data. Does not create appointments or financial transactions.';
