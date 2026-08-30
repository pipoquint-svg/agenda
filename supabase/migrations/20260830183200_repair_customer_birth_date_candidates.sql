-- Repair customer detail drift: admin-customers already calls this RPC, but it was absent in production.
-- The function is read-only and only exposes birth-date candidates for an authorized admin viewer.

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
  v_canonical date;
  v_candidates jsonb := '[]'::jsonb;
  v_has_conflict boolean := false;
begin
  if p_admin_id is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_admin_id, 'CUSTOMERS_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select c.birth_date
  into v_canonical
  from public.customers c
  where c.id = p_customer_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  with parsed as (
    select
      l.source,
      case
        when nullif(btrim(l.raw_snapshot->>'birth_date'), '') ~ '^\d{4}-\d{2}-\d{2}$'
          then (l.raw_snapshot->>'birth_date')::date
        when nullif(btrim(l.raw_snapshot->>'birth_date'), '') ~ '^\d{2}/\d{2}/\d{4}$'
          then to_date(l.raw_snapshot->>'birth_date', 'DD/MM/YYYY')
        else null
      end as birth_date
    from public.legacy_customer_sources l
    where l.customer_id = p_customer_id
      and l.raw_snapshot ? 'birth_date'
  ), grouped as (
    select
      birth_date,
      count(*)::integer as occurrence_count,
      array_agg(distinct source order by source) as event_sources
    from parsed
    where birth_date is not null
      and birth_date <= current_date
    group by birth_date
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'birth_date', g.birth_date,
        'occurrence_count', g.occurrence_count,
        'event_sources', to_jsonb(g.event_sources)
      )
      order by g.occurrence_count desc, g.birth_date desc
    ),
    '[]'::jsonb
  )
  into v_candidates
  from grouped g;

  select exists (
    select 1
    from jsonb_array_elements(v_candidates) candidate
    where v_canonical is not null
      and (candidate->>'birth_date')::date is distinct from v_canonical
  )
  or (
    select count(distinct candidate->>'birth_date') > 1
    from jsonb_array_elements(v_candidates) candidate
  )
  into v_has_conflict;

  return jsonb_build_object(
    'canonical_birth_date', v_canonical,
    'birth_date_locked', false,
    'has_conflict', coalesce(v_has_conflict, false),
    'candidates', v_candidates
  );
end;
$$;

revoke all on function public.service_admin_list_customer_birth_date_candidates(uuid, uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_customer_birth_date_candidates(uuid, uuid) to service_role;
