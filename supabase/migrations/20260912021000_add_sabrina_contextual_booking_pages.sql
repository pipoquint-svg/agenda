-- Gestante V2: contextual entry points for the two Sabrina Pierri experiences.
--
-- Keep the legacy `sabrina` page intact as a fallback. The new pages only select
-- existing services; pricing, availability, employees, extras and payment rules
-- remain authoritative on the existing service records.

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

-- Copy technical/payment configuration from the canonical Sabrina page while
-- giving each entry point its own editorial identity.
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
)
select
  'sabrina-essencial',
  'Sabrina Pierri · Essencial',
  'Agende seu ensaio Essencial',
  'Escolha o pacote contratado e encontre o melhor horário para você.',
  bp.brand_key,
  bp.logo_url,
  bp.accent_color,
  true,
  bp.sort_order + 1,
  bp.require_tax_id,
  bp.payment_provider
from public.booking_pages bp
where bp.slug = 'sabrina'
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
  updated_at = now();

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
)
select
  'sabrina-signature',
  'Sabrina Pierri · Signature',
  'Agende seu ensaio Signature',
  'Escolha o pacote contratado e encontre o melhor horário para você.',
  bp.brand_key,
  bp.logo_url,
  bp.accent_color,
  true,
  bp.sort_order + 2,
  bp.require_tax_id,
  bp.payment_provider
from public.booking_pages bp
where bp.slug = 'sabrina'
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
  updated_at = now();

-- Rebuild only the contextual page memberships. Existing service records are not
-- copied or changed.
delete from public.booking_page_services bps
using public.booking_pages bp
where bps.booking_page_id = bp.id
  and bp.slug in ('sabrina-essencial', 'sabrina-signature');

insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
select
  bp.id,
  s.id,
  case s.slug
    when 'essencial-10-fotos' then 10
    when 'essencial-20-fotos' then 20
  end,
  true
from public.booking_pages bp
join public.services s
  on s.slug in ('essencial-10-fotos', 'essencial-20-fotos')
where bp.slug = 'sabrina-essencial'
  and s.is_active;

insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
select
  bp.id,
  s.id,
  case s.slug
    when 'signature-20-fotos' then 10
    when 'signature-35-fotos' then 20
    when 'signature-40-fotos' then 30
  end,
  true
from public.booking_pages bp
join public.services s
  on s.slug in ('signature-20-fotos', 'signature-35-fotos', 'signature-40-fotos')
where bp.slug = 'sabrina-signature'
  and s.is_active;

-- Fail migration instead of silently publishing incomplete contextual pages.
do $block$
declare
  v_essencial_count integer;
  v_signature_count integer;
begin
  select count(*)
    into v_essencial_count
  from public.booking_page_services bps
  join public.booking_pages bp on bp.id = bps.booking_page_id
  where bp.slug = 'sabrina-essencial'
    and bps.is_active;

  select count(*)
    into v_signature_count
  from public.booking_page_services bps
  join public.booking_pages bp on bp.id = bps.booking_page_id
  where bp.slug = 'sabrina-signature'
    and bps.is_active;

  if v_essencial_count <> 2 then
    raise exception 'SABRINA_ESSENCIAL_CONTEXTUAL_PAGE_INVALID: expected 2 services, got %', v_essencial_count;
  end if;

  if v_signature_count <> 3 then
    raise exception 'SABRINA_SIGNATURE_CONTEXTUAL_PAGE_INVALID: expected 3 services, got %', v_signature_count;
  end if;
end
$block$;

commit;
