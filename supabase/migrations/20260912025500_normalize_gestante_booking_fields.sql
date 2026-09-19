-- Gestante V2 form normalization.
-- Payment method is owned by the checkout/payment flow and must not be asked as
-- a legacy service-field question. The father's name remains available but is
-- optional because its own label says it only applies when he participates.
--
-- Sabrina's commercial catalog is production-owned business data; clean CI
-- databases may not seed these services, so this migration is safely a no-op
-- when none of the target services exist.

begin;

do $block$
declare
  v_target_count integer;
begin
  select count(*)::integer
    into v_target_count
  from public.services
  where slug in (
    'essencial-10-fotos',
    'essencial-20-fotos',
    'signature-20-fotos',
    'signature-35-fotos',
    'signature-40-fotos'
  )
    and is_active;

  if v_target_count = 0 then
    raise notice 'Sabrina Gestante commercial catalog is not seeded; field normalization skipped.';
    return;
  end if;

  if v_target_count <> 5 then
    raise exception 'GESTANTE_SERVICE_CATALOG_PARTIAL:expected=5 actual=%', v_target_count;
  end if;

  -- Legacy question: the checkout itself is the authority for payment method.
  update public.service_fields sf
     set is_active = false,
         is_required = false
    from public.services s
   where s.id = sf.service_id
     and s.slug in (
       'essencial-10-fotos',
       'essencial-20-fotos',
       'signature-20-fotos',
       'signature-35-fotos',
       'signature-40-fotos'
     )
     and sf.field_key = 'pergunta_17';

  -- The field stays in the form, but only when applicable to the family.
  update public.service_fields sf
     set is_required = false
    from public.services s
   where s.id = sf.service_id
     and s.slug in (
       'essencial-10-fotos',
       'essencial-20-fotos',
       'signature-20-fotos',
       'signature-35-fotos',
       'signature-40-fotos'
     )
     and sf.field_key = 'pergunta_12';
end
$block$;

commit;
