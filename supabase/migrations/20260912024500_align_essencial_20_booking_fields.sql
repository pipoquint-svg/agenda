-- Gestante V2: Essencial 20 had no service_fields while Essencial 10 and the
-- Signature packages use the full session intake form. Copy the existing
-- Essencial field contract instead of inventing a second form.
--
-- Production owns the Sabrina service catalog as business data, while clean CI
-- databases may not seed it. The migration therefore becomes a no-op when the
-- commercial services are absent, but still fails closed on a partial/invalid
-- production-like catalog.

begin;

do $block$
declare
  v_source_id uuid;
  v_target_id uuid;
  v_source_exists boolean := false;
  v_target_exists boolean := false;
begin
  select id into v_source_id
  from public.services
  where slug = 'essencial-10-fotos' and is_active;

  v_source_exists := v_source_id is not null;

  select id into v_target_id
  from public.services
  where slug = 'essencial-20-fotos' and is_active;

  v_target_exists := v_target_id is not null;

  if not v_source_exists and not v_target_exists then
    raise notice 'Essencial commercial catalog is not seeded; booking-field alignment skipped.';
  elsif not v_source_exists then
    raise exception 'ESSENCIAL_10_SERVICE_NOT_FOUND';
  elsif not v_target_exists then
    raise exception 'ESSENCIAL_20_SERVICE_NOT_FOUND';
  elsif not exists (
    select 1 from public.service_fields
    where service_id = v_source_id and is_active
  ) then
    raise exception 'ESSENCIAL_10_FIELDS_NOT_FOUND';
  else
    insert into public.service_fields (
      service_id,
      field_key,
      label,
      field_type,
      help_text,
      placeholder,
      is_required,
      sort_order,
      options_json,
      is_active
    )
    select
      v_target_id,
      sf.field_key,
      sf.label,
      sf.field_type,
      sf.help_text,
      sf.placeholder,
      sf.is_required,
      sf.sort_order,
      sf.options_json,
      sf.is_active
    from public.service_fields sf
    where sf.service_id = v_source_id
    on conflict (service_id, field_key) do update set
      label = excluded.label,
      field_type = excluded.field_type,
      help_text = excluded.help_text,
      placeholder = excluded.placeholder,
      is_required = excluded.is_required,
      sort_order = excluded.sort_order,
      options_json = excluded.options_json,
      is_active = excluded.is_active;

    if exists (
      (
        select field_key, label, field_type, is_required, sort_order, options_json
        from public.service_fields
        where service_id = v_source_id and is_active
        except
        select field_key, label, field_type, is_required, sort_order, options_json
        from public.service_fields
        where service_id = v_target_id and is_active
      )
      union all
      (
        select field_key, label, field_type, is_required, sort_order, options_json
        from public.service_fields
        where service_id = v_target_id and is_active
        except
        select field_key, label, field_type, is_required, sort_order, options_json
        from public.service_fields
        where service_id = v_source_id and is_active
      )
    ) then
      raise exception 'ESSENCIAL_BOOKING_FIELDS_NOT_ALIGNED';
    end if;
  end if;
end
$block$;

commit;
