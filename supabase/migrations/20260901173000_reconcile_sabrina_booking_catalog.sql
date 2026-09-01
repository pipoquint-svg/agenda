begin;

-- Reconcile the Sabrina booking catalog to the production state validated on 2026-09-01.
-- Use business-stable keys only: generated UUIDs must not be required to replay this migration.
-- Signature services intentionally remain hidden until Sabrina's weekly availability is configured.

update public.services
set name = 'Essencial 20 fotos',
    short_description = '90 minutos de sessão, até 3 looks e fotos com o companheiro e a família.',
    full_description = 'Ensaio Essencial com 20 fotos editadas. Inclui 90 minutos de sessão, até 3 looks e fotos com o companheiro e a família.',
    checkout_minimum_payment_type = 'FIXED',
    checkout_minimum_payment_value = 100,
    payment_mode = 'MINIMUM_ONLY',
    card_max_installments = 1,
    pix_discount_percent = 0,
    public_minimum_booking_notice_hours = 24,
    updated_at = now()
where operation_scope = 'SABRINA'
  and slug = 'essencial-20-fotos';

update public.services
set base_price = 1590,
    base_duration_minutes = 180,
    short_description = 'Direção pessoal da Sabrina, 3 horas de sessão, até 4 looks (1 em moulage), fotos com o companheiro e a família e coffee break especial.',
    full_description = 'Linha Signature fotografada pela Sabrina. Premium 20 fotos: 3 horas de sessão, até 4 looks, sendo 1 em moulage, fotos com o companheiro e a família e coffee break especial.',
    updated_at = now()
where operation_scope = 'SABRINA'
  and slug = 'signature-20-fotos';

update public.services
set base_price = 1990,
    base_duration_minutes = 180,
    short_description = 'Tudo do Premium, com vídeo reels do ensaio, até 5 looks (2 em moulage), pendrive e 35 fotos impressas.',
    full_description = 'Linha Signature fotografada pela Sabrina. Exclusive 35 fotos: tudo do Premium, vídeo reels do ensaio, até 5 looks, sendo 2 em moulage, pendrive e 35 fotos impressas.',
    updated_at = now()
where operation_scope = 'SABRINA'
  and slug = 'signature-35-fotos';

update public.services
set slug = 'signature-40-fotos',
    base_price = 2990,
    base_duration_minutes = 180,
    short_description = 'Tudo do Exclusive, com álbum fotográfico 20×30 cm, até 6 looks (2 em moulage), pendrive e 40 fotos impressas.',
    full_description = 'Linha Signature fotografada pela Sabrina. Signature 40 fotos: tudo do Exclusive, álbum fotográfico 20×30 cm, até 6 looks, sendo 2 em moulage, pendrive e 40 fotos impressas.',
    updated_at = now()
where operation_scope = 'SABRINA'
  and (slug = 'signature-40-fotos' or name = 'Signature - 40 fotos');

-- Essencial 20 is served by the same employee as Essencial 10, so it inherits the same
-- weekly working windows. Slot generation still respects Essencial 20's own 90-minute duration.
with src_rules as (
  select
    src_se.employee_id,
    ar.weekday,
    ar.start_local_time,
    ar.end_local_time,
    ar.slot_interval_minutes,
    ar.is_active
  from public.services src_service
  join public.service_employees src_se
    on src_se.service_id = src_service.id
   and src_se.is_active = true
  join public.availability_rules ar
    on ar.service_employee_id = src_se.id
  where src_service.operation_scope = 'SABRINA'
    and src_service.slug = 'essencial-10-fotos'
), dst_relations as (
  select dst_se.id, dst_se.employee_id
  from public.services dst_service
  join public.service_employees dst_se
    on dst_se.service_id = dst_service.id
   and dst_se.is_active = true
  where dst_service.operation_scope = 'SABRINA'
    and dst_service.slug = 'essencial-20-fotos'
)
insert into public.availability_rules (
  service_employee_id,
  weekday,
  start_local_time,
  end_local_time,
  slot_interval_minutes,
  is_active
)
select
  dst.id,
  src.weekday,
  src.start_local_time,
  src.end_local_time,
  src.slot_interval_minutes,
  src.is_active
from src_rules src
join dst_relations dst on dst.employee_id = src.employee_id
where not exists (
  select 1
  from public.availability_rules existing
  where existing.service_employee_id = dst.id
    and existing.weekday = src.weekday
    and existing.start_local_time = src.start_local_time
    and existing.end_local_time = src.end_local_time
);

-- Ensure Essencial 20 is publicly selectable when both the page and service exist.
insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
select
  bp.id,
  s.id,
  1,
  true
from public.booking_pages bp
join public.services s
  on s.operation_scope = 'SABRINA'
 and s.slug = 'essencial-20-fotos'
where bp.slug = 'sabrina'
on conflict (booking_page_id, service_id)
do update set sort_order = excluded.sort_order, is_active = excluded.is_active;

-- Stable public order. Signature links stay present administratively but remain hidden.
update public.booking_page_services bps
set sort_order = desired.sort_order,
    is_active = desired.is_active
from public.booking_pages bp
join (
  values
    ('essencial-10-fotos'::text, 0, true),
    ('essencial-20-fotos'::text, 1, true),
    ('signature-20-fotos'::text, 2, false),
    ('signature-35-fotos'::text, 3, false),
    ('signature-40-fotos'::text, 4, false)
) as desired(service_slug, sort_order, is_active) on true
join public.services s
  on s.operation_scope = 'SABRINA'
 and s.slug = desired.service_slug
where bp.slug = 'sabrina'
  and bps.booking_page_id = bp.id
  and bps.service_id = s.id;

commit;
