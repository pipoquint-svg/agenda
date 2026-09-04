-- Keep Google-vs-Google overlap as a technical divergence for fail-closed
-- availability, but do not promote it to a critical operational alert when
-- the only current blocker is another active Google external block.
--
-- Any divergence with no provable current Google-only blocker, or with a
-- booking/hold/manual block, remains actionable and visible to Item C.

create or replace function public.service_list_ops_actionable_schedule_divergences(
  p_stale_before timestamptz
)
returns table(
  id uuid,
  source text,
  reason text,
  status text,
  detected_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    sd.id,
    sd.source,
    sd.reason,
    sd.status,
    sd.detected_at
  from public.schedule_divergences sd
  where sd.status = 'OPEN'
    and sd.detected_at <= p_stale_before
    and not (
      sd.source = 'GOOGLE'
      and sd.reason = 'GOOGLE_EVENT_CONFLICT'
      and exists (
        select 1
        from public.resource_allocations ra
        where ra.resource_id = sd.resource_id
          and ra.google_calendar_event_id is distinct from sd.google_calendar_event_id
          and ra.allocation_type = 'EXTERNAL_BLOCK'
          and ra.status = 'EXTERNAL_ACTIVE'
          and ra.external_source = 'GOOGLE'
          and ra.occupied_range && sd.desired_range
      )
      and not exists (
        select 1
        from public.resource_allocations ra
        where ra.resource_id = sd.resource_id
          and ra.google_calendar_event_id is distinct from sd.google_calendar_event_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && sd.desired_range
          and not (
            ra.allocation_type = 'EXTERNAL_BLOCK'
            and ra.status = 'EXTERNAL_ACTIVE'
            and ra.external_source = 'GOOGLE'
          )
          and (
            ra.status <> 'HELD'
            or ra.allocation_type <> 'CHECKOUT_HOLD'
            or exists (
              select 1
              from public.checkout_holds ch
              where ch.id = ra.checkout_hold_id
                and ch.status = 'ACTIVE'
                and ch.expires_at > now()
            )
          )
          and not (
            ra.status = 'AWAITING_PAYMENT'
            and ra.appointment_id is not null
            and exists (
              select 1
              from public.appointments a
              where a.id = ra.appointment_id
                and a.status = 'AWAITING_PAYMENT'
                and a.hold_expires_at is not null
                and a.hold_expires_at <= now()
            )
          )
      )
    )
  order by sd.detected_at, sd.id;
$function$;

revoke all on function public.service_list_ops_actionable_schedule_divergences(timestamptz) from public;
grant execute on function public.service_list_ops_actionable_schedule_divergences(timestamptz) to service_role;
