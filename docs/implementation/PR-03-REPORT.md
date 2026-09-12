# PR-03 — Month Availability Engine V2

## Legacy Architecture

`agenda_public_bridge.list_available_dates_month_impl` generates local days and invokes `public.list_available_slots_for_duration` once per day. The V1 wrapper then applies Google readiness, divergences and person-resource occupancy after the daily engine.

## Differential Harness

`158_monthly_availability_differential_harness.test.sql` introduces a test-only `LEGACY_MONTH` canonicalizer. It records normalized ordered `YYYY-MM-DD` dates, input, count and elapsed milliseconds; `elapsed_ms` is excluded from equality.

## Coverage Matrix (03-A)

| Scenario | Coverage | Evidence | Result |
|---|---|---|---|
| 28/29/30/31-day shapes and year boundary | DIRECT | 158 monthly harness | pending CI |
| weekly employee/resource availability | DIRECT | 158 monthly harness | pending CI |
| BLOCKS/MINUTES transport | COMBINED | 157 daily harness + 158 minutes input | pending CI |
| PREPEND/APPEND/same-resource merge | COMBINED | 157 range parity + 158 serialized selection | pending CI |
| OPEN/BLOCK, occupancy, bounds, Google/divergence | NOT YET COVERED | reserved for V2 differential fixtures | — |
| FIXED monthly path | NOT YET COVERED | legacy public month is duration-based | — |

## Public Endpoint

PUBLIC ENDPOINT STILL USES V1.

## Gate

03-A pending CI. No engine, migration, public contract or golden result has changed.
