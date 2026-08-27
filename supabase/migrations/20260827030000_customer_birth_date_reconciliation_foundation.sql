-- Issue #288 — explicit reconciliation between service-collected birth date and canonical customer birth_date.
-- No label/key inference, no historical answer rewrite, no automatic promotion and no birthday side effects.

alter table public.service_fields
  add column if not exists semantic_key text;

alter table public.service_fields
  drop constraint if exists service_fields_semantic_key_check;
alter table public.service_fields
  add constraint service_fields_semantic_key_check
  check (
    semantic_key is null
    or (semantic_key = 'CUSTOMER_BIRTH_DATE' and field_type = 'DATE')
  );

create unique index if not exists service_fields_service_semantic_key_uidx
  on public.service_fields(service_id, semantic_key)
  where semantic_key is not null;

comment on column public.service_fields.semantic_key is
  'Explicit semantic mapping for reconciliation. Never inferred from field_key, label or free text.';

alter table public.appointment_answers
  add column if not exists semantic_key_snapshot text;

alter table public.appointment_answers
  drop constraint if exists appointment_answers_semantic_key_snapshot_check;
alter table public.appointment_answers
  add constraint appointment_answers_semantic_key_snapshot_check
  check (semantic_key_snapshot is null or semantic_key_snapshot = 'CUSTOMER_BIRTH_DATE');

comment on column public.appointment_answers.semantic_key_snapshot is
  'Immutable-at-insert semantic meaning copied from service_fields. Existing historical answers remain null unless originally captured after semantic mapping exists.';

create or replace function public.service_snapshot_appointment_answer_semantic_key()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.service_field_id is null then
    new.semantic_key_snapshot := null;
  else
    select f.semantic_key
      into new.semantic_key_snapshot
    from public.service_fields f
    where f.id = new.service_field_id;
  end if;
  return new;
end;
$$;

revoke all on function public.service_snapshot_appointment_answer_semantic_key() from public, anon, authenticated;

drop trigger if exists trg_appointment_answers_semantic_snapshot on public.appointment_answers;
create trigger trg_appointment_answers_semantic_snapshot
before insert on public.appointment_answers
for each row execute function public.service_snapshot_appointment_answer_semantic_key();

create or replace function public.service_admin_set_service_field_semantic_key(
  p_service_field_id uuid,
  p_semantic_key text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := nullif(upper(btrim(coalesce(p_semantic_key, ''))), '');
  v_service_id uuid;
  v_field_type text;
  v_before text;
  v_after text;
begin
  if p_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if v_key is not null and v_key <> 'CUSTOMER_BIRTH_DATE' then
    raise exception using errcode = 'P0001', message = 'SERVICE_FIELD_SEMANTIC_KEY_INVALID';
  end if;

  select service_id, field_type, semantic_key
    into v_service_id, v_field_type, v_before
  from public.service_fields
  where id = p_service_field_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_FIELD_NOT_FOUND';
  end if;
  if v_key = 'CUSTOMER_BIRTH_DATE' and v_field_type <> 'DATE' then
    raise exception using errcode = 'P0001', message = 'SERVICE_FIELD_SEMANTIC_TYPE_MISMATCH';
  end if;

  begin
    update public.service_fields
    set semantic_key = v_key
    where id = p_service_field_id
    returning semantic_key into v_after;
  exception when unique_violation then
    raise exception using errcode = 'P0001', message = 'SERVICE_FIELD_SEMANTIC_KEY_DUPLICATE';
  end;

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (
      p_admin_id,
      'SERVICE_FIELD',
      p_service_field_id,
      'SERVICE_FIELD_SEMANTIC_MAPPING_CHANGED',
      jsonb_build_object('service_id', v_service_id, 'semantic_key', v_before),
      jsonb_build_object('service_id', v_service_id, 'semantic_key', v_after),
      'ADMIN'
    );
  end if;

  return jsonb_build_object(
    'service_field_id', p_service_field_id,
    'service_id', v_service_id,
    'semantic_key', v_after
  );
end;
$$;

revoke all on function public.service_admin_set_service_field_semantic_key(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_service_field_semantic_key(uuid,text,uuid) to service_role;

create or replace function public.service_try_iso_birth_date(p_value jsonb)
returns date
language plpgsql
immutable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_text text;
  v_date date;
begin
  if jsonb_typeof(p_value) <> 'string' then
    return null;
  end if;
  v_text := p_value #>> '{}';
  if v_text !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  begin
    v_date := v_text::date;
  exception when others then
    return null;
  end;
  if to_char(v_date, 'YYYY-MM-DD') <> v_text then
    return null;
  end if;
  return v_date;
end;
$$;

revoke all on function public.service_try_iso_birth_date(jsonb) from public, anon, authenticated;
grant execute on function public.service_try_iso_birth_date(jsonb) to service_role;

create or replace function public.service_admin_list_customer_birth_date_candidates(
  p_customer_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer_type text;
  v_canonical date;
  v_result jsonb;
begin
  if p_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_admin_id, 'CUSTOMERS_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select customer_type, birth_date
    into v_customer_type, v_canonical
  from public.customers
  where id = p_customer_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;
  if upper(coalesce(v_customer_type, '')) not in ('PERSON','PESSOA','INDIVIDUAL') then
    return jsonb_build_object('canonical_birth_date', v_canonical, 'candidates', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'appointment_answer_id', x.answer_id,
    'appointment_id', x.appointment_id,
    'appointment_public_code', x.public_code,
    'appointment_start_at', x.start_at,
    'service_name', x.service_name,
    'field_key_snapshot', x.field_key_snapshot,
    'label_snapshot', x.label_snapshot,
    'collected_birth_date', x.collected_birth_date,
    'canonical_birth_date', v_canonical,
    'matches_canonical', (v_canonical is not null and x.collected_birth_date = v_canonical),
    'needs_reconciliation', (v_canonical is distinct from x.collected_birth_date)
  ) order by x.start_at desc nulls last, x.answer_id), '[]'::jsonb)
    into v_result
  from (
    select
      aa.id as answer_id,
      a.id as appointment_id,
      a.public_code,
      a.start_at,
      a.service_name_snapshot as service_name,
      aa.field_key_snapshot,
      aa.label_snapshot,
      public.service_try_iso_birth_date(aa.value_json) as collected_birth_date
    from public.appointment_answers aa
    join public.appointments a on a.id = aa.appointment_id
    where a.primary_customer_id = p_customer_id
      and aa.semantic_key_snapshot = 'CUSTOMER_BIRTH_DATE'
      and public.service_try_iso_birth_date(aa.value_json) is not null
  ) x;

  return jsonb_build_object('canonical_birth_date', v_canonical, 'candidates', v_result);
end;
$$;

revoke all on function public.service_admin_list_customer_birth_date_candidates(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_customer_birth_date_candidates(uuid,uuid) to service_role;

comment on function public.service_admin_list_customer_birth_date_candidates(uuid,uuid) is
  'Read-only reconciliation candidates from explicitly snapshotted CUSTOMER_BIRTH_DATE answers. Never promotes or mutates canonical birth_date.';
