# PR-03 — Month Availability Engine V2

## Legacy Architecture

`agenda_public_bridge.list_available_dates_month_impl` generates local days and invokes `public.list_available_slots_for_duration` once per day. The V1 wrapper then applies Google readiness, divergences and person-resource occupancy after the daily engine.

## Differential Harness

`158_monthly_availability_differential_harness.test.sql` introduces a test-only `LEGACY_MONTH` canonicalizer. It records normalized ordered `YYYY-MM-DD` dates, input, count and elapsed milliseconds; `elapsed_ms` is excluded from equality.

## Coverage Matrix (03-A)

| Scenario | Coverage | Evidence | Result |
|---|---|---|---|
| 28/29/30/31-day shapes and year boundary | DIRECT | 158 monthly harness: `feb_28`, `feb_29`, `apr_30`, `dec_31` | PASS |
| weekly employee/resource availability | DIRECT | 158 monthly harness: Monday employee and resource windows | PASS |
| BLOCKS/MINUTES transport | COMBINED | 157 daily harness + 158 duration-input capture | PASS |
| PREPEND/APPEND/same-resource merge | COMBINED | 157 range parity + 158 serialized selection | PASS |
| OPEN/BLOCK, occupancy, bounds, Google/divergence | NOT YET COVERED | reserved for V2 differential fixtures | — |
| FIXED monthly path | NOT YET COVERED | legacy public month is duration-based | — |

## Public Endpoint

PUBLIC ENDPOINT STILL USES V1.

## Gate 03-A

**PASS** — validated on PR #438 head `a6996a02d8392c51a7e5fa80a366b0bb8605094c`.

The one composite deterministic fixture produced five legacy-month captures: four calendar-shape captures (`feb_28`, `feb_29`, `apr_30`, and `dec_31`) plus one selection capture with PREPEND and APPEND extras sharing a resource. It directly covers the listed month shapes, year boundary, and weekly employee/resource availability. It combines existing PR-01/PR-02 range and daily parity evidence for duration transport and merged extra-resource ranges.

OPEN/BLOCK exceptions, occupancy (appointment/active/expired hold), minimum notice, maximum horizon, Google conflict/staleness/divergence, and an independent FIXED monthly case remain **NOT YET COVERED** by the 03-A fixture. They are explicit requirements for the V1 × V2 differential matrix in Gate 03-B; they are not claimed as covered here.

No migration was created. No production SQL or public contract changed. No public cutover occurred; the public endpoint remains on V1.
