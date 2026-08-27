-- BlackSheep studio rental duration pricing staircase.
-- 30-minute blocks, with authoritative fixed/anchor rules requested for the public booking UX.
-- Service is resolved by stable slug; no generated IDs are hardcoded.

alter table public.service_duration_pricing_tiers
  alter column price_per_block type numeric(14,6)
  using price_per_block::numeric(14,6);

with target_service as (
  select id
  from public.services
  where slug = 'locacao-estudio'
    and operation_scope = 'BLACKSHEEP'
  limit 1
), desired(min_blocks, unit_price) as (
  values
    (2,  90.000000::numeric), -- 1h   = 180
    (3,  90.000000::numeric), -- 1h30 = 270
    (4,  85.000000::numeric), -- 2h   = 340 fixed
    (5,  85.000000::numeric), -- 2h30 = 425
    (6,  85.000000::numeric), -- 3h   = 510
    (7,  85.000000::numeric), -- 3h30 = 595
    (8,  85.000000::numeric), -- 4h   = 680
    (9,  85.555556::numeric), -- 4h30 = 770 (+90 per extra 30 min after 4h)
    (10, 86.000000::numeric), -- 5h   = 860
    (11, 86.363636::numeric), -- 5h30 = 950
    (12, 86.666667::numeric), -- 6h   = 1040
    (13, 86.923077::numeric), -- 6h30 = 1130
    (14, 87.142857::numeric), -- 7h   = 1220
    (15, 87.333333::numeric), -- 7h30 = 1310
    (16, 87.500000::numeric)  -- 8h   = 1400
)
update public.service_duration_pricing_tiers t
set price_per_block = d.unit_price,
    updated_at = now()
from target_service s
join desired d on true
where t.service_id = s.id
  and t.is_active = true
  and t.min_blocks = d.min_blocks
  and t.max_blocks = d.min_blocks;

-- Keep service fallback aligned with the first-hour 30-minute unit price.
update public.services
set base_price = 180.00,
    price_per_block = 90.00,
    updated_at = now()
where slug = 'locacao-estudio'
  and operation_scope = 'BLACKSHEEP';
