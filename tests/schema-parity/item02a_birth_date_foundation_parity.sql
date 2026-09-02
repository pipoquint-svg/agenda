\set ON_ERROR_STOP on

do $$
declare
  v_def text;
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='service_fields' and column_name='semantic_key'
  ) then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: service_fields.semantic_key';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='appointment_answers' and column_name='semantic_key_snapshot'
  ) then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: appointment_answers.semantic_key_snapshot';
  end if;

  if to_regclass('public.service_fields_service_semantic_key_uidx') is not null then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: service_fields_service_semantic_key_uidx';
  end if;

  if exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='appointment_answers'
      and t.tgname='trg_appointment_answers_semantic_snapshot'
      and not t.tgisinternal
  ) then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: trg_appointment_answers_semantic_snapshot';
  end if;

  if to_regprocedure('public.service_snapshot_appointment_answer_semantic_key()') is not null then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: service_snapshot_appointment_answer_semantic_key()';
  end if;

  if to_regprocedure('public.service_admin_set_service_field_semantic_key(uuid,text,uuid)') is not null then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: service_admin_set_service_field_semantic_key(uuid,text,uuid)';
  end if;

  if to_regprocedure('public.service_try_iso_birth_date(jsonb)') is not null then
    raise exception 'SCHEMA_PARITY_RESIDUE_PRESENT: service_try_iso_birth_date(jsonb)';
  end if;

  if to_regprocedure('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)') is null then
    raise exception 'SCHEMA_PARITY_CANONICAL_RPC_MISSING';
  end if;

  select pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)
    into v_def;

  if position('legacy_customer_sources' in v_def) = 0 then
    raise exception 'SCHEMA_PARITY_CANONICAL_RPC_WRONG_SOURCE';
  end if;

  if position('service_try_iso_birth_date' in v_def) > 0 then
    raise exception 'SCHEMA_PARITY_CANONICAL_RPC_STILL_DEPENDS_ON_RESIDUE';
  end if;
end
$$;
