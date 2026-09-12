-- Gestante V2: contextual entry points for the two Sabrina Pierri experiences.
--
-- Production already owns the Sabrina commercial catalog as business data. A
-- fresh local database used by CI does not necessarily seed that catalog, so
-- this migration must remain reset-safe when the canonical page/services are
-- absent. When the required production data exists, the contextual pages are
-- created from the existing records without copying service configuration.

begin;

-- InfinitePay remains explicitly scoped. Do not broaden this to every SABRINA page:
-- future pages must be reviewed before they can use this provider.
alter table public.booking_pages
  drop constraint if exists booking_pages_infinitepay_scope_check;

alter table public.booking_pages
  add constraint booking_pages_infinitepay_scope_check
  check (
    payment_provider <> 'INFINITEPAY'
    or (
      brand_key = 'SABRINA'
      and slug in (
        'sabrina',
        'sabrina-essencial',
        'sabrina-signature',
        'natal-2026'
      )
    )
  );

do $block$
declare
  v_source public.booking_pages%rowtype;
  v_essencial_count integer := 0;
  v_signature_count integer := 0;
  v_essencial_page_id uuid;
  v_signature_page_id uuid;
begin
  select *
    into v_source
  from public.booking_pages
  where slug = 'sabrina';

  if not found then
    raise notice 'Canonical Sabrina booking page is not seeded; contextual pages will be materialized when production migration runs against the commercial catalog.';
  else
    select count(*)::integer
      into v_essencial_count
    from public.services
    where is_active
      and slug in ('essencial-10-fotos', 'essencial-20-fotos');

    select count(*)::integer
      into v_signature_count
    from public.services
    where is_active
      and slug in ('signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos');

    if v_essencial_count = 2 then
      insert into public.booking_pages (
        slug,
        display_name,
        title,
        subtitle,
        brand_key,
        logo_url,
        accent_color,
        is_active,
        sort_order,
        require_tax_id,
        payment_provider
      ) values (
        'sabrina-essencial',
        'Sabrina Pierri · Essencial',
        'Agende seu ensaio Essencial',
        'Escolha o pacote contratado e encontre o melhor horário para você.',
        v_source.brand_key,
        v_source.logo_url,
        v_source.accent_color,
        true,
        v_source.sort_order + 1,
        v_source.require_tax_id,
        v_source.payment_provider
      )
      on conflict (slug) do update set
        display_name = excluded.display_name,
        title = excluded.title,
        subtitle = excluded.subtitle,
        brand_key = excluded.brand_key,
        logo_url = excluded.logo_url,
        accent_color = excluded.accent_color,
        is_active = excluded.is_active,
        sort_order = excluded.sort_order,
        require_tax_id = excluded.require_tax_id,
        payment_provider = excluded.payment_provider,
        updated_at = now()
      returning id into v_essencial_page_id;

      delete from public.booking_page_services
      where booking_page_id = v_essencial_page_id;

      insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
      select
        v_essencial_page_id,
        s.id,
        case s.slug
          when 'essencial-10-fotos' then 10
          when 'essencial-20-fotos' then 20
        end,
        true
      from public.services s
      where s.is_active
        and s.slug in ('essencial-10-fotos', 'essencial-20-fotos');
    else
      raise notice 'Essencial contextual page skipped: expected 2 active services, found %.', v_essencial_count;
    end if;

    if v_signature_count = 3 then
      insert into public.booking_pages (
        slug,
        display_name,
        title,
        subtitle,
        brand_key,
        logo_url,
        accent_color,
        is_active,
        sort_order,
        require_tax_id,
        payment_provider
      ) values (
        'sabrina-signature',
        'Sabrina Pierri · Signature',
        'Agende seu ensaio Signature',
        'Escolha o pacote contratado e encontre o melhor horário para você.',
        v_source.brand_key,
        v_source.logo_url,
        v_source.accent_color,
        true,
        v_source.sort_order + 2,
        v_source.require_tax_id,
        v_source.payment_provider
      )
      on conflict (slug) do update set
        display_name = excluded.display_name,
        title = excluded.title,
        subtitle = excluded.subtitle,
        brand_key = excluded.brand_key,
        logo_url = excluded.logo_url,
        accent_color = excluded.accent_color,
        is_active = excluded.is_active,
        sort_order = excluded.sort_order,
        require_tax_id = excluded.require_tax_id,
        payment_provider = excluded.payment_provider,
        updated_at = now()
      returning id into v_signature_page_id;

      delete from public.booking_page_services
      where booking_page_id = v_signature_page_id;

      insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
      select
        v_signature_page_id,
        s.id,
        case s.slug
          when 'signature-20-fotos' then 10
          when 'signature-35-fotos' then 20
          when 'signature-40-fotos' then 30
        end,
        true
      from public.services s
      where s.is_active
        and s.slug in ('signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos');
    else
      raise notice 'Signature contextual page skipped: expected 3 active services, found %.', v_signature_count;
    end if;
  end if;
end
$block$;

commit;
