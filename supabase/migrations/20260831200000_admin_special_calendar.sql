create table if not exists public.special_calendar_dates (
  id uuid primary key default gen_random_uuid(),
  local_date date not null unique,
  name text not null check (length(btrim(name)) between 1 and 160),
  category text not null check (category in ('NATIONAL','STATE','MUNICIPAL','FACULTATIVE','MANUAL')),
  treatment text not null check (treatment in ('SURCHARGE','NORMAL','CLOSED')),
  source_status text not null default 'MANUAL' check (source_status in ('OFFICIAL','PROJECTED','MANUAL')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.special_calendar_dates enable row level security;
revoke all on table public.special_calendar_dates from public, anon, authenticated;
grant select, insert, update, delete on table public.special_calendar_dates to service_role;

create index if not exists special_calendar_dates_year_idx
  on public.special_calendar_dates ((extract(year from local_date)));

alter table public.availability_exceptions
  add column if not exists special_calendar_date_id uuid references public.special_calendar_dates(id) on delete cascade;

create unique index if not exists availability_exceptions_resource_special_date_uidx
  on public.availability_exceptions(resource_id, special_calendar_date_id)
  where resource_id is not null and special_calendar_date_id is not null;

comment on table public.special_calendar_dates is
  'Calendario especial autoritativo da BlackSheep. SURCHARGE aplica adicional comercial, NORMAL neutraliza apenas o adicional de feriado e CLOSED materializa bloqueio do recurso fisico da locacao.';

comment on column public.availability_exceptions.special_calendar_date_id is
  'Preenchido apenas para bloqueios gerenciados automaticamente pelo Calendario especial.';

create or replace function public.blacksheep_special_date_treatment(p_date date)
returns text
language sql
stable
strict
set search_path = pg_catalog, public
as $function$
  select scd.treatment
  from public.special_calendar_dates scd
  where scd.local_date = p_date
  limit 1
$function$;

create or replace function public.blacksheep_rental_special_date(p_date date)
returns boolean
language sql
stable
strict
set search_path = pg_catalog, public
as $function$
  select coalesce(public.blacksheep_special_date_treatment(p_date) in ('SURCHARGE','CLOSED'), false)
$function$;

comment on function public.blacksheep_rental_special_date(date) is
  'Compatibilidade do motor de locacao: true para datas com acrescimo ou fechadas; NORMAL e datas ausentes retornam false.';

create or replace function public.blacksheep_sync_special_calendar_date(p_special_date_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_date date;
  v_name text;
  v_treatment text;
  v_start timestamptz;
  v_end timestamptz;
begin
  select local_date, name, treatment
    into v_date, v_name, v_treatment
  from public.special_calendar_dates
  where id = p_special_date_id;

  delete from public.availability_exceptions
  where special_calendar_date_id = p_special_date_id;

  if v_date is null or v_treatment <> 'CLOSED' then
    return;
  end if;

  v_start := v_date::timestamp at time zone 'America/Sao_Paulo';
  v_end := (v_date + 1)::timestamp at time zone 'America/Sao_Paulo';

  insert into public.availability_exceptions(
    resource_id,
    exception_type,
    start_at,
    end_at,
    reason,
    created_by,
    special_calendar_date_id
  )
  select
    r.id,
    'BLOCK',
    v_start,
    v_end,
    'Calendário especial · ' || v_name,
    null,
    p_special_date_id
  from public.resources r
  where upper(r.resource_type::text) <> 'PERSON'
    and exists (
      select 1
      from public.service_resources sr
      join public.services s on s.id = sr.service_id
      where sr.resource_id = r.id
        and s.slug = 'locacao-estudio'
        and s.operation_scope = 'BLACKSHEEP'
    )
  on conflict (resource_id, special_calendar_date_id)
    where resource_id is not null and special_calendar_date_id is not null
  do update set
    exception_type = excluded.exception_type,
    start_at = excluded.start_at,
    end_at = excluded.end_at,
    reason = excluded.reason,
    created_by = null;
end;
$function$;

create or replace function public.blacksheep_sync_all_closed_special_dates()
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid;
begin
  for v_id in select id from public.special_calendar_dates where treatment = 'CLOSED'
  loop
    perform public.blacksheep_sync_special_calendar_date(v_id);
  end loop;
end;
$function$;

revoke all on function public.blacksheep_sync_special_calendar_date(uuid) from public, anon, authenticated;
revoke all on function public.blacksheep_sync_all_closed_special_dates() from public, anon, authenticated;
grant execute on function public.blacksheep_sync_special_calendar_date(uuid) to service_role;
grant execute on function public.blacksheep_sync_all_closed_special_dates() to service_role;

create or replace function public.blacksheep_sync_special_calendar_on_service_resource()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.blacksheep_sync_all_closed_special_dates();
  return coalesce(new, old);
end;
$function$;

drop trigger if exists trg_blacksheep_special_calendar_service_resource on public.service_resources;
create trigger trg_blacksheep_special_calendar_service_resource
after insert or update or delete on public.service_resources
for each statement execute function public.blacksheep_sync_special_calendar_on_service_resource();

create or replace function public.service_admin_list_special_calendar_dates(
  p_start_year integer,
  p_end_year integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
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
        'created_at', scd.created_at,
        'updated_at', scd.updated_at
      )
      order by scd.local_date, scd.name
    )
    from public.special_calendar_dates scd
    where extract(year from scd.local_date)::integer between v_start and v_end
  ), '[]'::jsonb);
end;
$function$;

create or replace function public.service_admin_upsert_special_calendar_date_audited(
  p_id uuid,
  p_local_date date,
  p_name text,
  p_category text,
  p_treatment text,
  p_source_status text,
  p_notes text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid := p_id;
  v_name text := btrim(coalesce(p_name, ''));
  v_category text := upper(btrim(coalesce(p_category, '')));
  v_treatment text := upper(btrim(coalesce(p_treatment, '')));
  v_source_status text := upper(btrim(coalesce(p_source_status, '')));
  v_before jsonb;
  v_after jsonb;
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
  if v_category not in ('NATIONAL','STATE','MUNICIPAL','FACULTATIVE','MANUAL') then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_CATEGORY_INVALID';
  end if;
  if v_treatment not in ('SURCHARGE','NORMAL','CLOSED') then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_TREATMENT_INVALID';
  end if;
  if v_source_status not in ('OFFICIAL','PROJECTED','MANUAL') then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_SOURCE_STATUS_INVALID';
  end if;

  if (extract(month from p_local_date)::integer, extract(day from p_local_date)::integer) in ((1,1),(12,25))
     and v_treatment <> 'CLOSED' then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_PERMANENT_CLOSED';
  end if;

  if v_id is null then
    if exists (select 1 from public.special_calendar_dates where local_date = p_local_date) then
      raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_ALREADY_EXISTS';
    end if;

    insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
    values (
      p_local_date, v_name, v_category, v_treatment, v_source_status,
      nullif(btrim(coalesce(p_notes,'')), '')
    )
    returning id into v_id;
  else
    select to_jsonb(scd.*) into v_before
    from public.special_calendar_dates scd
    where scd.id = v_id
    for update;

    if v_before is null then
      raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_NOT_FOUND';
    end if;

    if exists (
      select 1 from public.special_calendar_dates
      where local_date = p_local_date and id <> v_id
    ) then
      raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_ALREADY_EXISTS';
    end if;

    update public.special_calendar_dates
    set local_date = p_local_date,
        name = v_name,
        category = v_category,
        treatment = v_treatment,
        source_status = v_source_status,
        notes = nullif(btrim(coalesce(p_notes,'')), ''),
        updated_at = now()
    where id = v_id;
  end if;

  perform public.blacksheep_sync_special_calendar_date(v_id);

  select to_jsonb(scd.*) into v_after
  from public.special_calendar_dates scd
  where scd.id = v_id;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id,
    'SPECIAL_CALENDAR_DATE',
    v_id,
    case when v_before is null then 'SPECIAL_DATE_CREATED' else 'SPECIAL_DATE_UPDATED' end,
    v_before,
    v_after,
    'ADMIN'
  );

  return v_after;
end;
$function$;

create or replace function public.service_admin_delete_special_calendar_date_audited(
  p_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_before jsonb;
  v_date date;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select scd.local_date, to_jsonb(scd.*)
    into v_date, v_before
  from public.special_calendar_dates scd
  where scd.id = p_id
  for update;

  if v_before is null then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_NOT_FOUND';
  end if;

  if (extract(month from v_date)::integer, extract(day from v_date)::integer) in ((1,1),(12,25)) then
    raise exception using errcode = 'P0001', message = 'SPECIAL_DATE_PERMANENT_CLOSED';
  end if;

  delete from public.special_calendar_dates where id = p_id;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'SPECIAL_CALENDAR_DATE', p_id, 'SPECIAL_DATE_DELETED', v_before, null, 'ADMIN'
  );

  return jsonb_build_object('deleted', true, 'id', p_id);
end;
$function$;

revoke all on function public.service_admin_list_special_calendar_dates(integer,integer,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_upsert_special_calendar_date_audited(uuid,date,text,text,text,text,text,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_delete_special_calendar_date_audited(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_special_calendar_dates(integer,integer,uuid) to service_role;
grant execute on function public.service_admin_upsert_special_calendar_date_audited(uuid,date,text,text,text,text,text,uuid) to service_role;
grant execute on function public.service_admin_delete_special_calendar_date_audited(uuid,uuid) to service_role;

do $seed$
declare
  v_year integer;
  v_a integer;
  v_b integer;
  v_c integer;
  v_d integer;
  v_e integer;
  v_f integer;
  v_g integer;
  v_h integer;
  v_i integer;
  v_k integer;
  v_l integer;
  v_m integer;
  v_month integer;
  v_day integer;
  v_easter date;
  v_mag_date date;
  v_mag_observed date;
  v_fac_status text;
begin
  for v_year in 2026..2030 loop
    insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
    values
      (make_date(v_year,1,1),'Confraternização Universal','NATIONAL','CLOSED','OFFICIAL','Fechamento permanente BlackSheep.'),
      (make_date(v_year,4,21),'Tiradentes','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,4,24),'Aniversário de Palhoça','MUNICIPAL','SURCHARGE','OFFICIAL','Feriado municipal de Palhoça.'),
      (make_date(v_year,5,1),'Dia Mundial do Trabalho','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,9,7),'Independência do Brasil','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,10,12),'Nossa Senhora Aparecida','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,11,2),'Finados','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,11,15),'Proclamação da República','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,11,20),'Dia Nacional de Zumbi e da Consciência Negra','NATIONAL','SURCHARGE','OFFICIAL',null),
      (make_date(v_year,12,25),'Natal','NATIONAL','CLOSED','OFFICIAL','Fechamento permanente BlackSheep.')
    on conflict (local_date) do nothing;

    v_a := v_year % 19;
    v_b := v_year / 100;
    v_c := v_year % 100;
    v_d := v_b / 4;
    v_e := v_b % 4;
    v_f := (v_b + 8) / 25;
    v_g := (v_b - v_f + 1) / 3;
    v_h := (19 * v_a + v_b - v_d - v_g + 15) % 30;
    v_i := v_c / 4;
    v_k := v_c % 4;
    v_l := (32 + 2 * v_e + 2 * v_i - v_h - v_k) % 7;
    v_m := (v_a + 11 * v_h + 22 * v_l) / 451;
    v_month := (v_h + v_l - 7 * v_m + 114) / 31;
    v_day := ((v_h + v_l - 7 * v_m + 114) % 31) + 1;
    v_easter := make_date(v_year, v_month, v_day);

    insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
    values
      (v_easter - 2,'Paixão de Cristo / Sexta-feira Santa','MUNICIPAL','SURCHARGE','OFFICIAL','Feriado municipal de Palhoça.'),
      (v_easter + 60,'Corpus Christi','MUNICIPAL','SURCHARGE','OFFICIAL','Feriado municipal de Palhoça.')
    on conflict (local_date) do nothing;

    v_mag_date := make_date(v_year,8,11);
    v_mag_observed := v_mag_date + ((7 - extract(dow from v_mag_date)::integer) % 7);
    insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
    values (
      v_mag_observed,
      'Data Magna de Santa Catarina',
      'STATE',
      'SURCHARGE',
      'OFFICIAL',
      format('Observância referente a 11/08/%s, transferida para o domingo subsequente quando aplicável.', v_year)
    )
    on conflict (local_date) do nothing;

    v_fac_status := case when v_year = 2026 then 'OFFICIAL' else 'PROJECTED' end;
    insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
    values
      (v_easter - 48,'Carnaval — segunda-feira','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then null else 'Data projetada; aguarda decreto anual.' end),
      (v_easter - 47,'Carnaval — terça-feira','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then null else 'Data projetada; aguarda decreto anual.' end),
      (v_easter - 46,'Quarta-feira de Cinzas','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then 'Tratamento comercial válido para o dia inteiro; expediente público pode ser parcial.'
             else 'Data projetada; aguarda decreto anual. Tratamento comercial válido para o dia inteiro.' end),
      (v_easter + 61,'Sexta-feira após Corpus Christi','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then 'Ponto facultativo de 2026.'
             else 'Data projetada; aguarda decreto anual.' end),
      (make_date(v_year,10,28),'Dia do Servidor Público','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then null else 'Data projetada; aguarda decreto anual.' end),
      (make_date(v_year,12,24),'Véspera de Natal','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then 'Tratamento comercial válido para o dia inteiro; expediente público pode ser parcial.'
             else 'Data projetada; aguarda decreto anual. Tratamento comercial válido para o dia inteiro.' end),
      (make_date(v_year,12,31),'Véspera de Ano Novo','FACULTATIVE','SURCHARGE',v_fac_status,
        case when v_year=2026 then 'Tratamento comercial válido para o dia inteiro; expediente público pode ser parcial.'
             else 'Data projetada; aguarda decreto anual. Tratamento comercial válido para o dia inteiro.' end)
    on conflict (local_date) do nothing;
  end loop;

  insert into public.special_calendar_dates(local_date,name,category,treatment,source_status,notes)
  values (
    date '2026-04-20',
    'Ponto facultativo — véspera de Tiradentes',
    'FACULTATIVE',
    'SURCHARGE',
    'OFFICIAL',
    'Ponto facultativo federal de 2026.'
  )
  on conflict (local_date) do nothing;
end;
$seed$;

select public.blacksheep_sync_all_closed_special_dates();

create or replace function public.service_admin_remove_resource_exception_audited(
  p_exception_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_before jsonb;
  v_special_calendar_date_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select
    jsonb_build_object(
      'id', ae.id,
      'resource_id', ae.resource_id,
      'exception_type', ae.exception_type,
      'start_at', ae.start_at,
      'end_at', ae.end_at,
      'reason', ae.reason,
      'created_at', ae.created_at
    ),
    ae.special_calendar_date_id
  into v_before, v_special_calendar_date_id
  from public.availability_exceptions ae
  where ae.id = p_exception_id
    and ae.resource_id is not null;

  if v_before is null then
    raise exception using errcode = 'P0001', message = 'RESOURCE_EXCEPTION_NOT_FOUND';
  end if;

  if v_special_calendar_date_id is not null then
    raise exception using errcode = 'P0001', message = 'RESOURCE_EXCEPTION_MANAGED_BY_SPECIAL_CALENDAR';
  end if;

  delete from public.availability_exceptions
  where id = p_exception_id;

  insert into public.audit_logs(
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_id,
    'RESOURCE_EXCEPTION',
    p_exception_id,
    'RESOURCE_EXCEPTION_DELETED',
    v_before,
    null,
    'ADMIN'
  );

  return v_before;
end;
$function$;

create or replace function public.service_admin_list_resource_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'resource_type', r.resource_type,
        'is_active', r.is_active,
        'availability_rules', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', rar.id,
              'weekday', rar.weekday,
              'start_local_time', rar.start_local_time,
              'end_local_time', rar.end_local_time,
              'is_active', rar.is_active
            ) order by rar.weekday, rar.start_local_time, rar.end_local_time, rar.id
          )
          from public.resource_availability_rules rar
          where rar.resource_id = r.id
        ), '[]'::jsonb),
        'exceptions', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', ae.id,
              'exception_type', ae.exception_type,
              'start_at', ae.start_at,
              'end_at', ae.end_at,
              'reason', ae.reason,
              'created_at', ae.created_at
            ) order by ae.start_at desc, ae.id
          )
          from public.availability_exceptions ae
          where ae.resource_id = r.id
            and ae.special_calendar_date_id is null
            and ae.end_at >= now() - interval '30 days'
        ), '[]'::jsonb),
        'service_bindings', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'service_id', sr.service_id,
              'service_name', s.name,
              'operation_scope', s.operation_scope,
              'is_required', sr.is_required
            ) order by s.sort_order, s.name, s.id
          )
          from public.service_resources sr
          join public.services s on s.id = sr.service_id
          where sr.resource_id = r.id
        ), '[]'::jsonb)
      ) order by r.name, r.id
    ),
    '[]'::jsonb
  )
  from public.resources r;
$function$;
