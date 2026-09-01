-- Remove the legacy inactive Sabrina employee only when it is fully orphaned.
-- This is intentionally predicate-based so generated IDs are never hardcoded.

delete from public.employees e
where e.name = 'Sabrina Pierri'
  and e.is_active = false
  and e.email is null
  and e.resource_id is null
  and not exists (
    select 1 from public.service_employees se where se.employee_id = e.id
  )
  and not exists (
    select 1 from public.google_connections gc where gc.employee_id = e.id
  )
  and not exists (
    select 1 from public.google_oauth_states gos where gos.employee_id = e.id
  );
