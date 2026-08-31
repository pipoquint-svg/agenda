-- Production received this migration version during a concurrent rollout after
-- 20260830210000_service_employee_range_anchor.sql had already become the
-- canonical repository migration for the same feature.
--
-- Keep the historical version in the repository so migration history remains
-- aligned with production, but do not apply the schema/function changes twice
-- during a clean rebuild.

do $migration$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'services'
      and column_name = 'slot_interval_minutes'
  ) then
    raise exception 'slot_interval_minutes prerequisite missing; expected 20260830210000 to run first';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'services'
      and c.conname = 'services_slot_interval_minutes_check'
  ) then
    raise exception 'services_slot_interval_minutes_check prerequisite missing';
  end if;

  if to_regprocedure('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)') is null
     or to_regprocedure('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)') is null then
    raise exception 'candidate-grid functions prerequisite missing';
  end if;
end;
$migration$;
