insert into public.resources (id, name, resource_type, is_active)
values
  ('00000000-0000-0000-0000-000000000101', 'ESTÚDIO', 'PHYSICAL', true),
  ('00000000-0000-0000-0000-000000000102', 'SABRINA', 'PERSON', true)
on conflict (id) do update
set name = excluded.name,
    resource_type = excluded.resource_type,
    is_active = excluded.is_active;

insert into public.employees (id, name, is_active, resource_id)
values (
  '00000000-0000-0000-0000-000000000201',
  'Sabrina',
  true,
  '00000000-0000-0000-0000-000000000102'
)
on conflict (id) do update
set name = excluded.name,
    is_active = excluded.is_active,
    resource_id = excluded.resource_id;
