begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);

select has_function(
  'public', 'service_admin_list_service_settings', array[]::text[],
  'admin service settings read model exists'
);

select has_function(
  'public', 'service_admin_update_timing',
  array['uuid','text','integer','integer','integer','integer','numeric','numeric','integer','integer'],
  'admin timing update function exists'
);

select has_function(
  'public', 'service_admin_replace_duration_configuration', array['uuid','jsonb','jsonb'],
  'admin duration configuration replacement exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer)', 'EXECUTE'),
  'anonymous users cannot update service timing'
);

insert into public.categories(id, name, slug)
values ('97300000-0000-0000-0000-000000000001', 'Admin Settings Test', 'admin-settings-test');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people,
  duration_mode
) values (
  '97300000-0000-0000-0000-000000000002',
  '97300000-0000-0000-0000-000000000001',
  'Sabrina Fixed Test', 'sabrina-fixed-admin-test',
  120, 500.00,
  0, 30,
  1, 10,
  'FIXED'
);

select lives_ok(
  $$ select public.service_admin_update_timing(
    '97300000-0000-0000-0000-000000000002',
    'FIXED', 150, null, null, null, 550.00, null, 0, 45
  ) $$,
  'admin can update fixed Sabrina-style duration and final buffer'
);

select is(
  (select base_duration_minutes from public.services where id = '97300000-0000-0000-0000-000000000002'),
  150,
  'fixed duration is persisted on the service'
);

select is(
  (select buffer_after_minutes from public.services where id = '97300000-0000-0000-0000-000000000002'),
  45,
  'buffer after is persisted independently from fixed duration'
);

select lives_ok(
  $$ select public.service_admin_update_timing(
    '97300000-0000-0000-0000-000000000002',
    'BLOCKS', 30, 30, 2, 16, 100.00, 100.00, 0, 30
  ) $$,
  'admin can switch a service to configurable 30-minute blocks'
);

select is(
  (select minimum_booking_blocks from public.services where id = '97300000-0000-0000-0000-000000000002'),
  2,
  'minimum block count is persisted'
);

select lives_ok(
  $$ select public.service_admin_replace_duration_configuration(
    '97300000-0000-0000-0000-000000000002',
    '[
      {"min_blocks":2,"max_blocks":3,"price_per_block":100,"sort_order":10},
      {"min_blocks":4,"max_blocks":7,"price_per_block":90,"sort_order":20},
      {"min_blocks":8,"max_blocks":16,"price_per_block":80,"sort_order":30}
    ]'::jsonb,
    '[
      {"block_count":2,"title":"Produção rápida","sort_order":10},
      {"block_count":4,"title":"Mais comum","badge":"Mais escolhido","is_featured":true,"sort_order":20},
      {"block_count":8,"title":"Produção completa","sort_order":30},
      {"block_count":16,"title":"Diária","sort_order":40}
    ]'::jsonb
  ) $$,
  'admin can replace pricing tiers and editorial presets atomically'
);

select is(
  (select count(*)::integer from public.service_duration_pricing_tiers where service_id = '97300000-0000-0000-0000-000000000002'),
  3,
  'three pricing tiers are stored'
);

select is(
  (select count(*)::integer from public.service_duration_presets where service_id = '97300000-0000-0000-0000-000000000002'),
  4,
  'four duration recommendation presets are stored'
);

select throws_ok(
  $$ select public.service_admin_replace_duration_configuration(
    '97300000-0000-0000-0000-000000000002',
    '[
      {"min_blocks":2,"max_blocks":5,"price_per_block":100},
      {"min_blocks":4,"max_blocks":8,"price_per_block":80}
    ]'::jsonb,
    '[]'::jsonb
  ) $$,
  'P0001', 'DURATION_PRICING_TIER_OVERLAP',
  'admin replacement cannot introduce overlapping active pricing tiers'
);

select is(
  (select jsonb_array_length(public.service_admin_list_service_settings())),
  (select count(*)::integer from public.services),
  'admin read model returns all configured services'
);

select * from finish();
rollback;
