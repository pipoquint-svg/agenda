begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.booking_pages'::regclass
      and conname = 'booking_pages_infinitepay_scope_check'
  ),
  'InfinitePay booking-page scope constraint exists'
);

-- A clean CI database does not seed the production Sabrina catalog. The
-- contextual slugs must still be valid members of the explicit provider scope.
insert into public.booking_pages(slug, display_name, title, brand_key, payment_provider)
values
  ('sabrina-essencial', 'Sabrina Pierri · Essencial', 'Agende seu ensaio Essencial', 'SABRINA', 'INFINITEPAY'),
  ('sabrina-signature', 'Sabrina Pierri · Signature', 'Agende seu ensaio Signature', 'SABRINA', 'INFINITEPAY')
on conflict (slug) do update set payment_provider = excluded.payment_provider;

select is(
  (select payment_provider from public.booking_pages where slug = 'sabrina-essencial'),
  'INFINITEPAY',
  'Essencial contextual slug is explicitly allowed to use InfinitePay'
);

select is(
  (select payment_provider from public.booking_pages where slug = 'sabrina-signature'),
  'INFINITEPAY',
  'Signature contextual slug is explicitly allowed to use InfinitePay'
);

-- If the production-like service catalog is present, the migration must have
-- materialized the exact membership. When the catalog is absent, reset safety is
-- the expected behavior and this invariant is intentionally vacuous.
select ok(
  (
    select count(*) from public.services
    where is_active and slug in ('essencial-10-fotos', 'essencial-20-fotos')
  ) <> 2
  or (
    select count(*)
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    join public.services s on s.id = bps.service_id
    where bp.slug = 'sabrina-essencial'
      and bps.is_active
      and s.slug in ('essencial-10-fotos', 'essencial-20-fotos')
  ) = 2,
  'Seeded Essencial catalog maps exactly two services to its contextual page'
);

select ok(
  (
    select count(*) from public.services
    where is_active and slug in ('signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos')
  ) <> 3
  or (
    select count(*)
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    join public.services s on s.id = bps.service_id
    where bp.slug = 'sabrina-signature'
      and bps.is_active
      and s.slug in ('signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos')
  ) = 3,
  'Seeded Signature catalog maps exactly three services to its contextual page'
);

insert into public.booking_pages(slug, display_name, title, brand_key, payment_provider)
values ('sabrina-unreviewed-context', 'Unreviewed Sabrina', 'Unreviewed Sabrina', 'SABRINA', 'MERCADO_PAGO');

select throws_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='sabrina-unreviewed-context' $$,
  '23514',
  null,
  'InfinitePay scope remains closed to unreviewed future Sabrina pages'
);

select ok(
  not exists (
    select 1
    from public.booking_pages
    where slug = 'sabrina-unreviewed-context'
      and payment_provider = 'INFINITEPAY'
  ),
  'Rejected provider update does not widen the persisted scope'
);

select * from finish();
rollback;
