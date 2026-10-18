-- Public studio totals for the BlackSheep home page: productions, booked hours
-- and professionals. Only three aggregate numbers leave the database; no
-- customer, employee or reservation data is exposed.
--
-- Business rules (2026-10-17):
-- * Count everything produced in the studio since May 2025, but only what has
--   already happened: a reservation counts once its scheduled end has passed.
-- * Sabrina Pierri's sessions count as productions and hours; Sabrina counts as
--   one professional and Jheneffe Pierri (Essencial sessions) as another, not
--   their end clients. Studio rentals count each renter as a professional.
-- * Free visits, meetings, personal appointments, blocks, cancellations,
--   no-shows and test reservations never count.
--
-- Sources:
-- * Until cutoff_at: a one-time snapshot of the Google Calendars "ESTÚDIO"
--   (atendimento@sabrinapierri.com.br) and agenda@blacksheepestudiocriativo.com.br,
--   which hold the Amelia, Appointlet and Agenda bookings since May 2025
--   (studio_stats_baselines).
-- * From cutoff_at on, live: realized Agenda reservations, the remaining Amelia
--   history (ADR-014) and the sessions booked straight on the ESTÚDIO calendar
--   outside the Agenda, as synced into google_calendar_events.

create table public.studio_stats_baselines (
  id smallint primary key default 1 check (id = 1),
  cutoff_at timestamptz not null,
  productions integer not null check (productions >= 0),
  hours numeric(10,1) not null check (hours >= 0),
  professionals integer not null check (professionals >= 0),
  source text not null,
  updated_at timestamptz not null default now()
);

alter table public.studio_stats_baselines enable row level security;
revoke all on public.studio_stats_baselines from public, anon, authenticated, service_role;
grant select on public.studio_stats_baselines to service_role;

comment on table public.studio_stats_baselines is
  'Single-row snapshot of studio productions before cutoff_at, counted from Google Calendar; public_get_studio_stats() adds live Agenda data after it.';

insert into public.studio_stats_baselines (cutoff_at, productions, hours, professionals, source)
values (
  '2026-10-17 00:00:00-03',
  666,
  1362.3,
  158,
  'Google Calendar ESTÚDIO + agenda@blacksheepestudiocriativo.com.br, 2025-05-03..2026-10-16: 279 rentals and 387 sessions; 156 renters plus Sabrina Pierri and Jheneffe Pierri'
);

create or replace function public.public_get_studio_stats()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  with baseline as (
    select
      coalesce(max(b.cutoff_at), '-infinity'::timestamptz) as cutoff_at,
      coalesce(max(b.productions), 0) as productions,
      coalesce(max(b.hours), 0) as hours,
      coalesce(max(b.professionals), 0) as professionals
    from public.studio_stats_baselines b
  ),
  agenda_rows as (
    select
      a.start_at,
      a.end_at,
      case
        when s.operation_scope = 'BLACKSHEEP' then 'c:' || coalesce(
          lower(nullif(btrim(c.email), '')),
          nullif(right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 11), ''),
          c.id::text,
          a.id::text
        )
        else 'p:' || coalesce(lower(nullif(btrim(e.name), '')), a.service_employee_id::text)
      end as professional_key
    from public.appointments a
    join public.services s on s.id = a.service_id
    left join public.customers c on c.id = a.primary_customer_id
    left join public.service_employees se on se.id = a.service_employee_id
    left join public.employees e on e.id = se.employee_id
    where not a.is_test
      and s.booking_product_type = 'STANDARD'
      and a.status in ('COMPLETED', 'CONFIRMED')
  ),
  amelia_rows as (
    select
      l.start_at,
      coalesce(l.end_at, l.start_at + make_interval(mins => coalesce(l.declared_duration_minutes, 0))) as end_at,
      case
        when nullif(btrim(l.employee_name), '') is null or l.employee_name ilike 'BlackSheep%' then 'c:' || coalesce(
          lower(nullif(btrim(coalesce(c.email, l.customer_email)), '')),
          nullif(right(regexp_replace(coalesce(c.phone, l.customer_phone, ''), '\D', '', 'g'), 11), ''),
          l.matched_customer_id::text,
          l.id::text
        )
        else 'p:' || lower(btrim(l.employee_name))
      end as professional_key
    from public.legacy_amelia_bookings l
    left join public.customers c on c.id = l.matched_customer_id
    where l.status_raw = 'Aprovado'
      and l.start_at is not null
      and coalesce(l.service_name, '') not ilike 'Conhecer%'
  ),
  -- Sessions booked straight on the ESTÚDIO calendar. Agenda-managed events are
  -- excluded because the reservation itself is counted in agenda_rows.
  calendar_events as (
    select distinct on (e.google_event_id)
      e.start_at,
      e.end_at,
      lower(translate(
        btrim(coalesce(e.summary, '')),
        'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
        'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'
      )) as title
    from public.google_calendar_events e
    join public.google_calendars gc on gc.id = e.google_calendar_id
    where gc.google_calendar_id = 'atendimento@sabrinapierri.com.br'
      and not e.managed_by_agenda
      and e.qualification = 'BLOCKING'
      and e.start_at is not null
      and e.end_at is not null
    order by e.google_event_id, e.updated_at desc
  ),
  calendar_rows as (
    select
      start_at,
      end_at,
      case
        when title ~ '(locacao|aluguel|gravacao|festival|^[0-9]+ *h(ora|oras)?\M|^volt\M)' then 'g:' || title
        when title ~ '(jheneffe|^essencial|gestante essencial)' then 'p:jheneffe pierri'
        else 'p:sabrina pierri'
      end as professional_key
    from calendar_events
    where title <> ''
      and title !~ '^(conhecer|compromisso|reuniao|mentoria|exame|bloqueio|aniversario|call\M|cafe\M|ttd\M|visita|almoco|sitio)'
  ),
  all_rows as (
    select * from agenda_rows
    union all
    select * from amelia_rows
    union all
    select * from calendar_rows
  ),
  live as (
    select r.*
    from all_rows r, baseline b
    where r.start_at >= b.cutoff_at
      and r.end_at <= now()
  ),
  known_before as (
    select distinct r.professional_key
    from all_rows r, baseline b
    where r.start_at < b.cutoff_at
  )
  select jsonb_build_object(
    'productions', b.productions + (select count(*) from live)::integer,
    'hours', floor(b.hours + coalesce((select sum(greatest(extract(epoch from (end_at - start_at)), 0)) from live), 0) / 3600)::integer,
    'professionals', b.professionals + (
      select count(distinct l.professional_key)
      from live l
      where not exists (select 1 from known_before k where k.professional_key = l.professional_key)
    )::integer,
    'updated_at', now()
  )
  from baseline b;
$$;

comment on function public.public_get_studio_stats() is
  'Public aggregate totals for the BlackSheep home page (productions, hours, professionals). Returns no personal data.';

revoke all on function public.public_get_studio_stats() from public;
grant execute on function public.public_get_studio_stats() to anon, authenticated, service_role;
