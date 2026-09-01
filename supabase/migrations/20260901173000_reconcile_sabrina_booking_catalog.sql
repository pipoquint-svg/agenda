begin;

-- Reconcile the Sabrina booking catalog to the production state validated on 2026-09-01.
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
where id = 'd96986a1-a49e-4d66-bae7-b30a0ba20907'::uuid;

update public.services
set base_price = 1590,
    base_duration_minutes = 180,
    short_description = 'Direção pessoal da Sabrina, 3 horas de sessão, até 4 looks (1 em moulage), fotos com o companheiro e a família e coffee break especial.',
    full_description = 'Linha Signature fotografada pela Sabrina. Premium 20 fotos: 3 horas de sessão, até 4 looks, sendo 1 em moulage, fotos com o companheiro e a família e coffee break especial.',
    updated_at = now()
where id = 'd60f2671-1e13-4408-9e5f-d1fe2ebb8aa7'::uuid;

update public.services
set base_price = 1990,
    base_duration_minutes = 180,
    short_description = 'Tudo do Premium, com vídeo reels do ensaio, até 5 looks (2 em moulage), pendrive e 35 fotos impressas.',
    full_description = 'Linha Signature fotografada pela Sabrina. Exclusive 35 fotos: tudo do Premium, vídeo reels do ensaio, até 5 looks, sendo 2 em moulage, pendrive e 35 fotos impressas.',
    updated_at = now()
where id = '9df4aa00-8f9d-455b-802b-6f29973a9d13'::uuid;

update public.services
set slug = 'signature-40-fotos',
    base_price = 2990,
    base_duration_minutes = 180,
    short_description = 'Tudo do Exclusive, com álbum fotográfico 20×30 cm, até 6 looks (2 em moulage), pendrive e 40 fotos impressas.',
    full_description = 'Linha Signature fotografada pela Sabrina. Signature 40 fotos: tudo do Exclusive, álbum fotográfico 20×30 cm, até 6 looks, sendo 2 em moulage, pendrive e 40 fotos impressas.',
    updated_at = now()
where id = '19a9291b-a504-4b6d-ae20-91d7f18c95a3'::uuid;

-- Essencial 20 is served by the same employee as Essencial 10, so it inherits the same
-- weekly working windows. Slot generation still respects Essencial 20's own 90-minute duration.
insert into public.availability_rules (
  service_employee_id,
  weekday,
  start_local_time,
  end_local_time,
  slot_interval_minutes,
  is_active
)
select
  '1f7f6adb-cd0e-4c1f-aa2c-dbb62e1ad671'::uuid,
  src.weekday,
  src.start_local_time,
  src.end_local_time,
  src.slot_interval_minutes,
  src.is_active
from public.availability_rules src
where src.service_employee_id = '557a98f4-22bf-47b4-be66-3c56b7b0f315'::uuid
  and exists (
    select 1
    from public.service_employees dst_se
    where dst_se.id = '1f7f6adb-cd0e-4c1f-aa2c-dbb62e1ad671'::uuid
  )
  and not exists (
    select 1
    from public.availability_rules dst
    where dst.service_employee_id = '1f7f6adb-cd0e-4c1f-aa2c-dbb62e1ad671'::uuid
      and dst.weekday = src.weekday
      and dst.start_local_time = src.start_local_time
      and dst.end_local_time = src.end_local_time
  );

-- Ensure Essencial 20 is publicly selectable when both the page and service exist.
insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
select
  bp.id,
  s.id,
  1,
  true
from public.booking_pages bp
join public.services s on s.id = 'd96986a1-a49e-4d66-bae7-b30a0ba20907'::uuid
where bp.id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
on conflict (booking_page_id, service_id)
do update set sort_order = excluded.sort_order, is_active = excluded.is_active;

-- Stable public order. Signature links stay present administratively but remain hidden.
update public.booking_page_services
set sort_order = 0,
    is_active = true
where booking_page_id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
  and service_id = 'd50514e4-f047-4fe8-b5e1-9f38fefa0681'::uuid;

update public.booking_page_services
set sort_order = 1,
    is_active = true
where booking_page_id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
  and service_id = 'd96986a1-a49e-4d66-bae7-b30a0ba20907'::uuid;

update public.booking_page_services
set sort_order = 2,
    is_active = false
where booking_page_id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
  and service_id = 'd60f2671-1e13-4408-9e5f-d1fe2ebb8aa7'::uuid;

update public.booking_page_services
set sort_order = 3,
    is_active = false
where booking_page_id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
  and service_id = '9df4aa00-8f9d-455b-802b-6f29973a9d13'::uuid;

update public.booking_page_services
set sort_order = 4,
    is_active = false
where booking_page_id = '1a371e23-14ec-4cd3-9742-41adc32b5bc0'::uuid
  and service_id = '19a9291b-a504-4b6d-ae20-91d7f18c95a3'::uuid;

commit;
