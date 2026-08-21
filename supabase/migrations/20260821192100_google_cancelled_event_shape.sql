alter table public.google_calendar_events
  drop constraint google_calendar_events_check;

alter table public.google_calendar_events
  add constraint google_calendar_events_time_shape_check
  check (
    status = 'cancelled'
    or (
      is_all_day
      and start_date is not null
      and end_date is not null
      and end_date > start_date
    )
    or (
      not is_all_day
      and start_at is not null
      and end_at is not null
      and end_at > start_at
    )
  );

comment on constraint google_calendar_events_time_shape_check on public.google_calendar_events is
  'Cancelled recurring instances may be sparse; active events require a valid timed or all-day interval.';
