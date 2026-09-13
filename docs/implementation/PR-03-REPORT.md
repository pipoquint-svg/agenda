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

## V2 Architecture (03-B)

`agenda_internal.list_available_dates_month_v2(...)` is an additive, private PL/pgSQL entry point with one set-based `RETURN QUERY` pipeline for the complete local month. It has a fixed empty `search_path`; `PUBLIC`, `anon`, and `authenticated` receive no EXECUTE grant. The existing `agenda_public_bridge.list_available_dates_month_impl` is deliberately untouched and continues to call V1.

Pipeline phases are: month bounds; weekly and employee-OPEN candidate generation; candidate schedule profile; notice/horizon bounds; employee containment and BLOCK checks; per-candidate resource ranges; resource availability/allocation/divergence checks; employee-person Google/divergence/allocation checks; and final distinct local dates.

### Request constants

The V2 resolves the canonical duration blocks and contracted minutes, public selection validation, active service, employee linkage, operation timezone, service buffers, slot interval, booking bounds, employee person resource, and that person's Google readiness once per invocation. `operation_settings.id = 1` is explicitly retained as **LEGACY SINGLE-TENANT COMPATIBILITY**.

### Candidate-specific semantics

Anchor/core/appointment ranges, `resolve_extra_schedule_profile`, PREPEND/APPEND, resource occupied ranges, weekly/OPEN/BLOCK containment, allocation overlap, schedule-divergence overlap, and employee-person interval conflicts remain candidate-specific. Resource ranges use the PR-02 seam `agenda_internal.calculate_booking_resource_ranges_resolved_duration(...)`.

### Pricing avoidance

V1's monthly result is an existence-of-date response. The V2 does not call `calculate_booking_quote_for_duration(...)`: the current duration engine obtains its scheduling pre/post values from `resolve_extra_schedule_profile(...)`, while commercial value is not used by the monthly predicate. Duration and public selection validation remain the existing canonical public functions.

### Google semantics

Employee-person readiness is request-constant because it depends only on the validated employee resource. Required booking-resource readiness is structurally deduplicated in two materialized stages: `distinct_resource_ids` derives IDs from `resource_ranges`, then `resource_google_readiness` invokes `google_resource_sync_is_ready` only from that distinct relation. Readiness is applied only to candidates using that resource. Divergences and allocations remain range predicates. No fail-closed condition was relaxed.

## Coverage Matrix (03-B)

| Scenario | Coverage type | Fixture/assertion | V1 | V2 | Parity |
|---|---|---|---|---|---|
| 28/29/30/31 days; year boundary | DIRECT | `feb_28`, `feb_29`, `apr_30`, `dec_31` | PASS | PASS | PASS |
| BLOCKS and minutes transport | DIRECT | BLOCKS service through the public contracted-minutes monthly bridge | PASS | PASS | PASS |
| FIXED | DIRECT | `fixed` | PASS | PASS | PASS |
| PREPEND, APPEND, merged resource | COMBINED | 158 monthly selection plus 157 resource-range parity | PASS | PASS | PASS |
| employee OPEN/BLOCK | DIRECT | `employee_open`, `employee_block` | PASS | PASS | PASS |
| resource OPEN/BLOCK | DIRECT | `employee_open`, `resource_block` with resource windows | PASS | PASS | PASS |
| confirmed appointment/allocation | DIRECT | `confirmed` | PASS | PASS | PASS |
| active checkout hold | DIRECT | `active_hold` | PASS | PASS | PASS |
| expired checkout hold | DIRECT | `expired_person_hold` | PASS | PASS | PASS |
| expired AWAITING_PAYMENT | DIRECT | `expired_awaiting` | PASS | PASS | PASS |
| PERSON / EXTERNAL_ACTIVE occupancy | DIRECT | `external_person` | PASS | PASS | PASS |
| minimum notice minutes | DIRECT | `minimum_notice` with `agenda.test_now` | PASS | PASS | PASS |
| public notice hours | DIRECT | `public_notice_pre`, `public_notice_post`, relative to `now()` | PASS | PASS | PASS |
| maximum horizon | DIRECT | `maximum_horizon` | PASS | PASS | PASS |
| Google healthy | DIRECT | `google_healthy` | PASS | PASS | PASS |
| material and PERSON stale fail-closed | DIRECT | `google_material_stale`, `google_person_stale` | PASS | PASS | PASS |
| material and PERSON Google divergence | DIRECT | `google_material_divergence`, `google_person_divergence` | PASS | PASS | PASS |

**NOT YET COVERED = 0** for the legacy monthly contract.

## Gate 03-B

**PASS** — validated on PR #438 head `b70c6bf01a1a516a6cddd37c501bb9d548d90181` before this documentation update. The monthly differential harness has 23 captured V1/V2 cases and 51 pgTAP assertions. Its direct cases establish the complete ordered local-date set, rather than only counts. The final documentation commit requires the same complete CI gate again.

Confirmed structural improvement: V1 enters `public.list_available_slots_for_duration` per local day; V2 executes one month-scoped pipeline and resolves request constants once. Latency improvement is not claimed here; that is Gate 03-C.

## Rollback and deferred work

Rollback is logical and immediate: leave the public bridge on V1 (as it already is) and do not invoke the private V2. PR-04 is the only planned cutover point, contingent on Gate 03-C benchmarks. No cutover, merge, or public contract change is included in PR-03.
