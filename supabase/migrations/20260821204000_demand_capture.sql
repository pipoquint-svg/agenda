create table public.demand_capture (
  id uuid primary key default gen_random_uuid(),

  name text not null,
  whatsapp text not null,
  email text not null,

  brand text not null,
  service_label text not null,
  desired_date date,
  desired_period text,
  notes text,

  source text not null default 'site',
  campaign text,

  consent_contact boolean not null default false,
  consent_text_version text not null,
  consent_at timestamptz,

  status text not null default 'NEW',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint demand_capture_name_length check (char_length(btrim(name)) >= 2),
  constraint demand_capture_period_check check (
    desired_period is null or desired_period in ('MANHA','TARDE','NOITE','INDIFERENTE')
  ),
  constraint demand_capture_status_check check (
    status in ('NEW','CONTACTED','CONVERTED','DISCARDED')
  ),
  constraint demand_capture_notes_length check (
    notes is null or char_length(notes) <= 300
  ),
  constraint demand_capture_consent_shape check (
    consent_contact = true and consent_at is not null
  )
);

create index demand_capture_created_at_idx
  on public.demand_capture (created_at desc);

create index demand_capture_campaign_idx
  on public.demand_capture (campaign)
  where campaign is not null;

create index demand_capture_dedupe_lookup_idx
  on public.demand_capture (whatsapp, service_label, desired_date, created_at desc);

alter table public.demand_capture enable row level security;
revoke all on table public.demand_capture from anon, authenticated;

create or replace function public.create_or_touch_demand_capture(
  p_name text,
  p_whatsapp text,
  p_email text,
  p_brand text,
  p_service_label text,
  p_desired_date date,
  p_desired_period text,
  p_notes text,
  p_source text,
  p_campaign text,
  p_consent_contact boolean,
  p_consent_text_version text,
  p_consent_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_existing_id uuid;
  v_id uuid;
  v_today date;
  v_recent_count integer;
  v_lock_key bigint;
begin
  if p_consent_contact is distinct from true or p_consent_at is null then
    raise exception using errcode = 'P0001', message = 'CONSENT_REQUIRED';
  end if;

  v_today := (now() at time zone 'America/Sao_Paulo')::date;
  if p_desired_date is not null and p_desired_date < v_today then
    raise exception using errcode = 'P0001', message = 'DESIRED_DATE_IN_PAST';
  end if;

  v_lock_key := hashtextextended(
    concat_ws('|', p_whatsapp, p_service_label, coalesce(p_desired_date::text, 'NULL')),
    0
  );
  perform pg_advisory_xact_lock(v_lock_key);

  select dc.id into v_existing_id
  from public.demand_capture dc
  where dc.whatsapp = p_whatsapp
    and dc.service_label = p_service_label
    and dc.desired_date is not distinct from p_desired_date
    and dc.created_at >= now() - interval '24 hours'
  order by dc.created_at desc
  limit 1
  for update;

  if v_existing_id is not null then
    update public.demand_capture
    set updated_at = now()
    where id = v_existing_id;

    return jsonb_build_object('id', v_existing_id, 'created', false);
  end if;

  select count(*)::integer into v_recent_count
  from public.demand_capture dc
  where dc.whatsapp = p_whatsapp
    and dc.created_at >= now() - interval '1 hour';

  if v_recent_count >= 5 then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  insert into public.demand_capture (
    name,
    whatsapp,
    email,
    brand,
    service_label,
    desired_date,
    desired_period,
    notes,
    source,
    campaign,
    consent_contact,
    consent_text_version,
    consent_at
  ) values (
    btrim(p_name),
    p_whatsapp,
    lower(btrim(p_email)),
    p_brand,
    p_service_label,
    p_desired_date,
    p_desired_period,
    nullif(btrim(p_notes), ''),
    coalesce(nullif(btrim(p_source), ''), 'site'),
    nullif(btrim(p_campaign), ''),
    true,
    p_consent_text_version,
    p_consent_at
  ) returning id into v_id;

  return jsonb_build_object('id', v_id, 'created', true);
end;
$$;

create or replace function public.demand_capture_summary(
  p_brand text default null,
  p_campaign text default null,
  p_service_label text default null,
  p_created_from timestamptz default null,
  p_created_to timestamptz default null,
  p_desired_from date default null,
  p_desired_to date default null,
  p_status text default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with filtered as (
  select *
  from public.demand_capture dc
  where (p_brand is null or dc.brand = p_brand)
    and (p_campaign is null or dc.campaign = p_campaign)
    and (p_service_label is null or dc.service_label = p_service_label)
    and (p_created_from is null or dc.created_at >= p_created_from)
    and (p_created_to is null or dc.created_at < p_created_to)
    and (p_desired_from is null or dc.desired_date >= p_desired_from)
    and (p_desired_to is null or dc.desired_date <= p_desired_to)
    and (p_status is null or dc.status = p_status)
), by_date as (
  select coalesce(jsonb_agg(jsonb_build_object('date', desired_date, 'count', count_value) order by count_value desc, desired_date), '[]'::jsonb) value
  from (
    select desired_date, count(*)::integer count_value
    from filtered
    where desired_date is not null
    group by desired_date
  ) x
), by_period as (
  select coalesce(jsonb_agg(jsonb_build_object('period', desired_period, 'count', count_value) order by count_value desc, desired_period), '[]'::jsonb) value
  from (
    select desired_period, count(*)::integer count_value
    from filtered
    where desired_period is not null
    group by desired_period
  ) x
), by_service as (
  select coalesce(jsonb_agg(jsonb_build_object('service', service_label, 'count', count_value) order by count_value desc, service_label), '[]'::jsonb) value
  from (
    select service_label, count(*)::integer count_value
    from filtered
    group by service_label
  ) x
)
select jsonb_build_object(
  'total', (select count(*)::integer from filtered),
  'by_date', (select value from by_date),
  'by_period', (select value from by_period),
  'by_service', (select value from by_service)
);
$$;

revoke all on function public.create_or_touch_demand_capture(text,text,text,text,text,date,text,text,text,text,boolean,text,timestamptz) from public, anon, authenticated;
revoke all on function public.demand_capture_summary(text,text,text,timestamptz,timestamptz,date,date,text) from public, anon, authenticated;

grant execute on function public.create_or_touch_demand_capture(text,text,text,text,text,date,text,text,text,text,boolean,text,timestamptz) to service_role;
grant execute on function public.demand_capture_summary(text,text,text,timestamptz,timestamptz,date,date,text) to service_role;
