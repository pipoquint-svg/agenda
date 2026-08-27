-- Hotfix discovered during controlled production pre-live validation.
--
-- Progressive 30-minute duration pricing can require repeating decimals at the
-- per-block level (for example R$ 260 / 3 blocks). With numeric(12,2), the
-- stored unit price rounds before multiplication and produces cent-level drift
-- in the authoritative commercial total.
--
-- Keep final monetary totals rounded to 2 decimals in the pricing engine, but
-- retain enough precision in the intermediate per-block rate to reproduce the
-- exact commercial table.

alter table public.services
  alter column price_per_block type numeric(14,6)
  using price_per_block::numeric(14,6);

alter table public.service_duration_pricing_tiers
  alter column price_per_block type numeric(14,6)
  using price_per_block::numeric(14,6);
