-- Item 2A prerequisite — reconcile rebuild-only customer birth-date foundation residue.
-- Production does not contain these objects, while a clean rebuild currently does.
-- This migration is intentionally idempotent and fail-closed:
-- - no CASCADE;
-- - refuses to drop either semantic column when non-null data exists;
-- - unexpected dependencies make the migration fail instead of being removed implicitly.

do $$
declare
  v_non_null bigint;
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'service_fields'
      and column_name = 'semantic_key'
  ) then
    execute 'select count(*) from public.service_fields where semantic_key is not null'
      into v_non_null;
    if v_non_null > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'SCHEMA_PARITY_SERVICE_FIELDS_SEMANTIC_KEY_HAS_DATA';
    end if;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'appointment_answers'
      and column_name = 'semantic_key_snapshot'
  ) then
    execute 'select count(*) from public.appointment_answers where semantic_key_snapshot is not null'
      into v_non_null;
    if v_non_null > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'SCHEMA_PARITY_APPOINTMENT_ANSWERS_SEMANTIC_KEY_HAS_DATA';
    end if;
  end if;
end
$$;

drop trigger if exists trg_appointment_answers_semantic_snapshot
  on public.appointment_answers;

drop index if exists public.service_fields_service_semantic_key_uidx;

alter table public.service_fields
  drop constraint if exists service_fields_semantic_key_check;

alter table public.appointment_answers
  drop constraint if exists appointment_answers_semantic_key_snapshot_check;

drop function if exists public.service_admin_set_service_field_semantic_key(uuid, text, uuid);
drop function if exists public.service_try_iso_birth_date(jsonb);
drop function if exists public.service_snapshot_appointment_answer_semantic_key();

alter table public.service_fields
  drop column if exists semantic_key;

alter table public.appointment_answers
  drop column if exists semantic_key_snapshot;
