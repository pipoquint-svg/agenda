-- BlackSheep rental commercial hours: client-facing booking may run until 22:00.
-- The post-service buffer remains an internal resource occupation and may extend
-- 30 minutes beyond closing, so the physical studio resource stays available
-- through 22:30 for allocation purposes only.
--
-- Scope is intentionally limited to the staging BlackSheep rental service by
-- stable slug. Environments without this synthetic service are a no-op.

update public.availability_rules ar
set end_local_time = '22:00'::time,
    updated_at = now()
from public.service_employees se
join public.services s on s.id = se.service_id
where ar.service_employee_id = se.id
  and s.slug = 'staging-locacao-blacksheep-duracao'
  and ar.is_active;

update public.resource_availability_rules rar
set end_local_time = '22:30'::time,
    updated_at = now()
where rar.resource_id in (
  select sr.resource_id
  from public.service_resources sr
  join public.services s on s.id = sr.service_id
  where s.slug = 'staging-locacao-blacksheep-duracao'
    and sr.is_required
)
  and rar.is_active;
