begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(2);

select ok(
  not exists (
    select 1
    from public.services s
    join public.service_fields sf on sf.service_id = s.id
    where s.slug in (
      'essencial-10-fotos',
      'essencial-20-fotos',
      'signature-20-fotos',
      'signature-35-fotos',
      'signature-40-fotos'
    )
      and sf.field_key = 'pergunta_17'
      and sf.is_active
  ),
  'Legacy payment-method question is not active for Gestante services'
);

select ok(
  not exists (
    select 1
    from public.services s
    join public.service_fields sf on sf.service_id = s.id
    where s.slug in (
      'essencial-10-fotos',
      'essencial-20-fotos',
      'signature-20-fotos',
      'signature-35-fotos',
      'signature-40-fotos'
    )
      and sf.field_key = 'pergunta_12'
      and sf.is_active
      and sf.is_required
  ),
  'Father name remains available but is optional for Gestante services'
);

select * from finish();
rollback;
