-- Gestante V2: Essencial 20 had no service_fields while Essencial 10 and the
-- Signature packages use the full session intake form. Copy the existing
-- Essencial field contract instead of inventing a second form.
--
-- This migration does not relax or remove any required field. It only makes the
-- two Essencial packages consistent until the form is later reorganized into
-- progressive visual sections.

begin;

do $block$
declare
  v_source_id uuid;
  v_target_id uuid;
begin
  select id into v_source_id
  from public.services
  where slug = 'essencial-10-fotos' and is_active;

  select id into v_target_id
  from public.services
  where slug = 'essencial-20-fotos' and is_active;

  if v_source_id is null then
    raise exception 'ESSENCIAL_10_SERVICE_NOT_FOUND';
  end if;

  if v_target_id is null then
    raise exception 'ESSENCIAL_20_SERVICE_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.service_fields
    where service_id = v_source_id and is_active
  ) then
    raise exception 'ESSENCIAL_10_FIELDS_NOT_FOUND';
  end if;

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
end
$block$;

commit;
