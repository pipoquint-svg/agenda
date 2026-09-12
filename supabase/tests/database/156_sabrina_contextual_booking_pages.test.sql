begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(9);

select is(
  public.public_get_booking_page('sabrina-essencial')->>'slug',
  'sabrina-essencial',
  'Essencial contextual booking page is public'
);

select is(
  jsonb_array_length(public.public_get_booking_page('sabrina-essencial')->'services'),
  2,
  'Essencial contextual page exposes exactly two services'
);

select is(
  (
    select array_agg(item->>'slug' order by item->>'slug')
    from jsonb_array_elements(public.public_get_booking_page('sabrina-essencial')->'services') item
  ),
  array['essencial-10-fotos', 'essencial-20-fotos']::text[],
  'Essencial contextual page exposes only Essencial packages'
);

select is(
  public.public_get_booking_page('sabrina-signature')->>'slug',
  'sabrina-signature',
  'Signature contextual booking page is public'
);

select is(
  jsonb_array_length(public.public_get_booking_page('sabrina-signature')->'services'),
  3,
  'Signature contextual page exposes exactly three services'
);

select is(
  (
    select array_agg(item->>'slug' order by item->>'slug')
    from jsonb_array_elements(public.public_get_booking_page('sabrina-signature')->'services') item
  ),
  array['signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos']::text[],
  'Signature contextual page exposes only Signature packages'
);

select is(
  (
    select array_agg(payment_provider order by slug)
    from public.booking_pages
    where slug in ('sabrina-essencial', 'sabrina-signature')
  ),
  array['INFINITEPAY', 'INFINITEPAY']::text[],
  'Both contextual Sabrina pages inherit InfinitePay'
);

select ok(
  public.public_get_booking_page('sabrina') is not null,
  'Legacy Sabrina page remains available as fallback'
);

insert into public.booking_pages(slug, display_name, title, brand_key, payment_provider)
values ('sabrina-unreviewed-context', 'Unreviewed Sabrina', 'Unreviewed Sabrina', 'SABRINA', 'MERCADO_PAGO');

select throws_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='sabrina-unreviewed-context' $$,
  '23514',
  null,
  'InfinitePay scope remains closed to unreviewed future Sabrina pages'
);

select * from finish();
rollback;
