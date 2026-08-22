begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

insert into public.categories(id, name, slug)
values ('97200000-0000-0000-0000-000000000001', 'Progressive Pricing Test', 'progressive-pricing-test');

insert into public.resources(id, name, resource_type)
values ('97200000-0000-0000-0000-000000000002', 'PROGRESSIVE TEST PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values ('97200000-0000-0000-0000-000000000003', 'Progressive Test Employee', '97200000-0000-0000-0000-000000000002');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '97200000-0000-0000-0000-000000000004',
  '97200000-0000-0000-0000-000000000001',
  'Locação Progressiva Test', 'locacao-progressiva-test',
  30, 100.00,
  0, 30,
  1, 20,
  'BLOCKS', 30, 2, 16, 100.00
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '97200000-0000-0000-0000-000000000005',
  '97200000-0000-0000-0000-000000000004',
  '97200000-0000-0000-0000-000000000003'
);

insert into public.booking_page_services(booking_page_id, service_id, sort_order)
select id, '97200000-0000-0000-0000-000000000004', 999
from public.booking_pages where slug = 'blacksheep';

select is(
  (public.resolve_service_duration_pricing('97200000-0000-0000-0000-000000000004', 4)->>'base_price')::numeric(12,2),
  400.00::numeric(12,2),
  'legacy service price remains the fallback when no tiers exist'
);

insert into public.service_duration_pricing_tiers(service_id, min_blocks, max_blocks, price_per_block, sort_order)
values
  ('97200000-0000-0000-0000-000000000004', 2, 3, 100.00, 10),
  ('97200000-0000-0000-0000-000000000004', 4, 7, 90.00, 20),
  ('97200000-0000-0000-0000-000000000004', 8, 16, 80.00, 30);

select is(
  (public.resolve_service_duration_pricing('97200000-0000-0000-0000-000000000004', 2)->>'unit_price')::numeric(12,2),
  100.00::numeric(12,2),
  'short rental keeps the first unit price'
);

select is(
  (public.resolve_service_duration_pricing('97200000-0000-0000-0000-000000000004', 4)->>'unit_price')::numeric(12,2),
  90.00::numeric(12,2),
  'longer rental resolves a lower unit price'
);

select is(
  (public.resolve_service_duration_pricing('97200000-0000-0000-0000-000000000004', 8)->>'unit_price')::numeric(12,2),
  80.00::numeric(12,2),
  'four-hour rental resolves the deepest configured unit price'
);

select is(
  (public.public_quote_booking_duration(
    'blacksheep',
    '97200000-0000-0000-0000-000000000004',
    '97200000-0000-0000-0000-000000000005',
    4, '[]'::jsonb, 1
  )->>'commercial_value')::numeric(12,2),
  360.00::numeric(12,2),
  'authoritative public quote uses the matching progressive tier'
);

select is(
  (public.public_quote_booking_duration(
    'blacksheep',
    '97200000-0000-0000-0000-000000000004',
    '97200000-0000-0000-0000-000000000005',
    8, '[]'::jsonb, 1
  )->>'commercial_value')::numeric(12,2),
  640.00::numeric(12,2),
  'eight blocks price from the lower duration tier'
);

select is(
  (public.public_quote_booking_duration(
    'blacksheep',
    '97200000-0000-0000-0000-000000000004',
    '97200000-0000-0000-0000-000000000005',
    4, '[]'::jsonb, 1
  )->>'duration_unit_price')::numeric(12,2),
  90.00::numeric(12,2),
  'quote exposes the resolved unit price for transparent UI display'
);

select is(
  (public.public_quote_booking_duration(
    'blacksheep',
    '97200000-0000-0000-0000-000000000004',
    '97200000-0000-0000-0000-000000000005',
    4, '[]'::jsonb, 1
  )->>'buffer_after_minutes')::integer,
  30,
  'progressive pricing does not change the single final service buffer'
);

select throws_ok(
  $$ insert into public.service_duration_pricing_tiers(service_id, min_blocks, max_blocks, price_per_block)
     values ('97200000-0000-0000-0000-000000000004', 3, 5, 50.00) $$,
  'P0001', 'DURATION_PRICING_TIER_OVERLAP',
  'overlapping active pricing tiers are rejected'
);

insert into public.service_duration_presets(service_id, block_count, title, description, badge, is_featured, sort_order)
values
  ('97200000-0000-0000-0000-000000000004', 2, 'Produção rápida', 'Uma hora para produções objetivas.', null, false, 10),
  ('97200000-0000-0000-0000-000000000004', 4, 'Escolha mais comum', 'Duas horas com mais liberdade.', 'Mais escolhido', true, 20),
  ('97200000-0000-0000-0000-000000000004', 8, 'Produção completa', 'Quatro horas para campanhas.', null, false, 30),
  ('97200000-0000-0000-0000-000000000004', 16, 'Diária de produção', 'Oito horas para produções extensas.', null, false, 40);

select is(
  (select jsonb_array_length(service_json->'duration_pricing_tiers')
   from jsonb_array_elements(public.public_get_booking_page('blacksheep')->'services') service_json
   where service_json->>'id' = '97200000-0000-0000-0000-000000000004'),
  3,
  'public catalog exposes active duration pricing tiers'
);

select is(
  (select jsonb_array_length(service_json->'duration_presets')
   from jsonb_array_elements(public.public_get_booking_page('blacksheep')->'services') service_json
   where service_json->>'id' = '97200000-0000-0000-0000-000000000004'),
  4,
  'public catalog exposes editorial duration presets independently from pricing tiers'
);

select is(
  (select preset->>'badge'
   from jsonb_array_elements(public.public_get_booking_page('blacksheep')->'services') service_json,
        lateral jsonb_array_elements(service_json->'duration_presets') preset
   where service_json->>'id' = '97200000-0000-0000-0000-000000000004'
     and (preset->>'block_count')::integer = 4),
  'Mais escolhido',
  'public duration preset can carry commercial recommendation copy'
);

select ok(
  not has_table_privilege('anon', 'public.service_duration_pricing_tiers', 'SELECT'),
  'anonymous clients cannot query authoritative pricing tables directly'
);

select ok(
  not has_table_privilege('authenticated', 'public.service_duration_presets', 'SELECT'),
  'authenticated clients cannot query preset tables directly outside the safe catalog function'
);

select * from finish();
rollback;
