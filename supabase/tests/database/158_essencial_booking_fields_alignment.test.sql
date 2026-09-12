begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

select ok(
  exists (
    select 1 from public.services
    where slug = 'essencial-10-fotos' and is_active
  ),
  'Essencial 10 source service exists'
);

select ok(
  exists (
    select 1 from public.services
    where slug = 'essencial-20-fotos' and is_active
  ),
  'Essencial 20 target service exists'
);

select is(
  (
    select count(*)::integer
    from public.service_fields sf
    join public.services s on s.id = sf.service_id
    where s.slug = 'essencial-20-fotos'
      and sf.is_active
  ),
  (
    select count(*)::integer
    from public.service_fields sf
    join public.services s on s.id = sf.service_id
    where s.slug = 'essencial-10-fotos'
      and sf.is_active
  ),
  'Essencial 20 has the same active field count as Essencial 10'
);

select is(
  (
    select count(*)::integer
    from (
      (
        select sf.field_key, sf.label, sf.field_type, sf.is_required, sf.sort_order, sf.options_json
        from public.service_fields sf
        join public.services s on s.id = sf.service_id
        where s.slug = 'essencial-10-fotos' and sf.is_active
        except
        select sf.field_key, sf.label, sf.field_type, sf.is_required, sf.sort_order, sf.options_json
        from public.service_fields sf
        join public.services s on s.id = sf.service_id
        where s.slug = 'essencial-20-fotos' and sf.is_active
      )
      union all
      (
        select sf.field_key, sf.label, sf.field_type, sf.is_required, sf.sort_order, sf.options_json
        from public.service_fields sf
        join public.services s on s.id = sf.service_id
        where s.slug = 'essencial-20-fotos' and sf.is_active
        except
        select sf.field_key, sf.label, sf.field_type, sf.is_required, sf.sort_order, sf.options_json
        from public.service_fields sf
        join public.services s on s.id = sf.service_id
        where s.slug = 'essencial-10-fotos' and sf.is_active
      )
    ) diff
  ),
  0,
  'Essencial 10 and 20 expose the same active field contract'
);

select * from finish();
rollback;
