create or replace function public.special_calendar_holiday_key(p_name text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(
    lower(translate(btrim(coalesce(p_name, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')),
    '[[:space:]]+',
    ' ',
    'g'
  );
$$;

create table if not exists public.special_calendar_recurrence_rules (
  id uuid primary key default gen_random_uuid(),
  holiday_key text not null,
  holiday_name text not null,
  start_year integer not null check (start_year between 2000 and 2200),
  enabled boolean not null default true,
  treatment text not null check (treatment in ('SURCHARGE','NORMAL','CLOSED')),
  created_by uuid null,
  updated_by uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint special_calendar_recurrence_rules_key_year_unique unique (holiday_key, start_year),
  constraint special_calendar_recurrence_rules_key_check check (length(btrim(holiday_key)) between 1 and 160),
  constraint special_calendar_recurrence_rules_name_check check (length(btrim(holiday_name)) between 1 and 160)
);

alter table public.special_calendar_recurrence_rules enable row level security;
revoke all on table public.special_calendar_recurrence_rules from public, anon, authenticated;
grant select, insert, update, delete on table public.special_calendar_recurrence_rules to service_role;
revoke all on function public.special_calendar_holiday_key(text) from public, anon, authenticated;
grant execute on function public.special_calendar_holiday_key(text) to service_role;

create index if not exists special_calendar_recurrence_rules_lookup_idx
  on public.special_calendar_recurrence_rules (holiday_key, start_year desc);

create or replace function public.special_calendar_apply_recurrence_on_write()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_enabled boolean;
  v_treatment text;
begin
  if (extract(month from new.local_date)::integer, extract(day from new.local_date)::integer) in ((1,1),(12,25)) then
    new.treatment := 'CLOSED';
    return new;
  end if;

  select r.enabled, r.treatment
    into v_enabled, v_treatment
  from public.special_calendar_recurrence_rules r
  where r.holiday_key = public.special_calendar_holiday_key(new.name)
    and r.start_year <= extract(year from new.local_date)::integer
  order by r.start_year desc
  limit 1;

  if found and v_enabled then
    new.treatment := v_treatment;
  end if;

  return new;
end;
$$;

revoke all on function public.special_calendar_apply_recurrence_on_write() from public, anon, authenticated;

create trigger special_calendar_apply_recurrence_before_write
before insert or update of local_date, name
on public.special_calendar_dates
for each row
execute function public.special_calendar_apply_recurrence_on_write();

create or replace function public.special_calendar_sync_after_write()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.blacksheep_sync_special_calendar_date(new.id);
  return new;
end;
$$;

revoke all on function public.special_calendar_sync_after_write() from public, anon, authenticated;

create trigger special_calendar_sync_after_write
after insert or update of local_date, name, treatment
on public.special_calendar_dates
for each row
execute function public.special_calendar_sync_after_write();

create or replace function public.service_admin_upsert_special_calendar_date_recurring_audited(
  p_id uuid,
  p_local_date date,
  p_name text,
  p_category text,
  p_treatment text,
  p_source_status text,
  p_notes text,
  p_repeat_future_years boolean,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_treatment text := upper(btrim(coalesce(p_treatment, '')));
  v_key text;
  v_year integer;
  v_existing_enabled boolean;
  v_result jsonb;
  v_row record;
  v_effective record;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_local_date is null then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_DATE_INVALID';
  end if;
  if length(v_name) < 1 or length(v_name) > 160 then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_NAME_INVALID';
  end if;
  if v_treatment not in ('SURCHARGE','NORMAL','CLOSED') then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_TREATMENT_INVALID';
  end if;

  v_key := public.special_calendar_holiday_key(v_name);
  v_year := extract(year from p_local_date)::integer;

  if coalesce(p_repeat_future_years, false) then
    insert into public.special_calendar_recurrence_rules(
      holiday_key, holiday_name, start_year, enabled, treatment, created_by, updated_by
    ) values (
      v_key, v_name, v_year, true, v_treatment, p_admin_id, p_admin_id
    )
    on conflict (holiday_key, start_year) do update
      set holiday_name = excluded.holiday_name,
          enabled = true,
          treatment = excluded.treatment,
          updated_by = excluded.updated_by,
          updated_at = now();
  else
    select r.enabled
      into v_existing_enabled
    from public.special_calendar_recurrence_rules r
    where r.holiday_key = v_key
      and r.start_year <= v_year
    order by r.start_year desc
    limit 1;

    if found and v_existing_enabled then
      insert into public.special_calendar_recurrence_rules(
        holiday_key, holiday_name, start_year, enabled, treatment, created_by, updated_by
      ) values (
        v_key, v_name, v_year, false, v_treatment, p_admin_id, p_admin_id
      )
      on conflict (holiday_key, start_year) do update
        set holiday_name = excluded.holiday_name,
            enabled = false,
            treatment = excluded.treatment,
            updated_by = excluded.updated_by,
            updated_at = now();
    end if;
  end if;

  v_result := public.service_admin_upsert_special_calendar_date_audited(
    p_id,
    p_local_date,
    p_name,
    p_category,
    p_treatment,
    p_source_status,
    p_notes,
    p_admin_id
  );

  if coalesce(p_repeat_future_years, false) then
    for v_row in
      select scd.id, scd.local_date
      from public.special_calendar_dates scd
      where public.special_calendar_holiday_key(scd.name) = v_key
        and extract(year from scd.local_date)::integer >= v_year
      order by scd.local_date
    loop
      select r.enabled, r.treatment, r.start_year
        into v_effective
      from public.special_calendar_recurrence_rules r
      where r.holiday_key = v_key
        and r.start_year <= extract(year from v_row.local_date)::integer
      order by r.start_year desc
      limit 1;

      if found and v_effective.enabled then
        update public.special_calendar_dates scd
        set treatment = case
              when (extract(month from scd.local_date)::integer, extract(day from scd.local_date)::integer) in ((1,1),(12,25)) then 'CLOSED'
              else v_effective.treatment
            end,
            updated_at = now()
        where scd.id = v_row.id;
      end if;
    end loop;
  end if;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id,
    'SPECIAL_CALENDAR_RECURRENCE',
    (v_result ->> 'id')::uuid,
    case when coalesce(p_repeat_future_years, false) then 'SPECIAL_DATE_RECURRENCE_ENABLED' else 'SPECIAL_DATE_RECURRENCE_DISABLED' end,
    null,
    jsonb_build_object(
      'holiday_key', v_key,
      'holiday_name', v_name,
      'start_year', v_year,
      'enabled', coalesce(p_repeat_future_years, false),
      'treatment', v_treatment
    ),
    'ADMIN'
  );

  select to_jsonb(scd.*) || jsonb_build_object(
    'repeat_future_years', coalesce((
      select r.enabled
      from public.special_calendar_recurrence_rules r
      where r.holiday_key = public.special_calendar_holiday_key(scd.name)
        and r.start_year <= extract(year from scd.local_date)::integer
      order by r.start_year desc
      limit 1
    ), false),
    'recurrence_start_year', (
      select r.start_year
      from public.special_calendar_recurrence_rules r
      where r.holiday_key = public.special_calendar_holiday_key(scd.name)
        and r.start_year <= extract(year from scd.local_date)::integer
      order by r.start_year desc
      limit 1
    )
  ) into v_result
  from public.special_calendar_dates scd
  where scd.id = (v_result ->> 'id')::uuid;

  return v_result;
end;
$$;

revoke all on function public.service_admin_upsert_special_calendar_date_recurring_audited(uuid,date,text,text,text,text,text,boolean,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_special_calendar_date_recurring_audited(uuid,date,text,text,text,text,text,boolean,uuid) to service_role;

create or replace function public.service_admin_list_special_calendar_dates(p_start_year integer, p_end_year integer, p_admin_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_start integer := coalesce(p_start_year, extract(year from current_date)::integer);
  v_end integer := coalesce(p_end_year, v_start);
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if v_start < 2000 or v_end > 2200 or v_end < v_start or (v_end - v_start) > 20 then
    raise exception using errcode = 'P0001', message = 'SPECIAL_CALENDAR_YEAR_RANGE_INVALID';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', scd.id,
        'local_date', scd.local_date,
        'name', scd.name,
        'category', scd.category,
        'treatment', scd.treatment,
        'source_status', scd.source_status,
        'notes', scd.notes,
        'is_permanent_closed',
          (extract(month from scd.local_date)::integer, extract(day from scd.local_date)::integer) in ((1,1),(12,25)),
        'repeat_future_years', coalesce((
          select r.enabled
          from public.special_calendar_recurrence_rules r
          where r.holiday_key = public.special_calendar_holiday_key(scd.name)
            and r.start_year <= extract(year from scd.local_date)::integer
          order by r.start_year desc
          limit 1
        ), false),
        'recurrence_start_year', (
          select r.start_year
          from public.special_calendar_recurrence_rules r
          where r.holiday_key = public.special_calendar_holiday_key(scd.name)
            and r.start_year <= extract(year from scd.local_date)::integer
          order by r.start_year desc
          limit 1
        ),
        'created_at', scd.created_at,
        'updated_at', scd.updated_at
      )
      order by scd.local_date, scd.name
    )
    from public.special_calendar_dates scd
    where extract(year from scd.local_date)::integer between v_start and v_end
  ), '[]'::jsonb);
end;
$$;
