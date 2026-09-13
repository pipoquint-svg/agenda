# CURRENT HANDOFF — Agenda

## Active PR

PR #439
Branch: `codex/agenda-pr04-month-engine-cutover`
Current validated HEAD: `fe2fd062f6e91ca87744488f85dff1e23e779d11`.

Current PR rules:
- keep PR draft
- do not merge
- do not start PR-05

## Completed

### Gate 03-B
PASS.

The monthly V1 × V2 parity matrix is complete, including exceptions, occupancy, bounds, duration modes, extras/resource ranges, Google readiness/divergences, calendar shapes, and year boundary.

### Gate 03-C — representative benchmark
PASS pending final documentation-head CI.

Authoritative GitHub Actions workflow `Month Availability V2 Benchmark`, run `34757040792`, succeeded on a GitHub-hosted Ubuntu runner using Supabase CLI 2.111.0 and disposable local Supabase/PostgreSQL. The dedicated fixture is transaction-scoped and rolls back after measurement.

Each scenario has ordered full-date V1/V2 parity, two warmups, and seven measured samples per engine. Median results: frequent 1046.270/243.210 ms (4.3019x), low 183.626/40.614 ms (4.5212x), zero 19.493/1.028 ms (18.9621x), resource-heavy 1041.971/236.905 ms (4.3983x), extras 1338.345/362.294 ms (3.6941x), occupancy 548.742/236.437 ms (2.3209x), all V1/V2 respectively. Google/divergence is not reliably timing-benchmarkable in the dedicated fixture; Gate 03-B provides its direct functional parity.

EXPLAIN is honestly limited to Function Scan for the PL/pgSQL entry point. The benchmark report contains the exact observable rows/timing/buffer values and names no index candidate.

PR-03 is merged into `main` as PR #438. Its V2 remains the implementation introduced by the controlled PR-04 cutover below.

## Current gate

## PR-04 — Controlled Month V2 Cutover

PASS on head `fe2fd062f6e91ca87744488f85dff1e23e779d11`.

Migration `20260913110000_month_availability_v2_cutover.sql` preserves the V1 monthly implementation as private `agenda_internal.list_available_dates_month_v1_legacy(...)` (SECURITY DEFINER, fixed empty search path, no EXECUTE for PUBLIC/anon/authenticated) and changes only `agenda_public_bridge.list_available_dates_month_impl(...)` to call V2. The public wrapper signature, return shape, grants, and SECURITY INVOKER/DEFINER boundary remain unchanged.

The harness captures V1 oracle × V2 and public bridge × V2 at the same fixture state for every scenario. Database Core, canonical rebuild, migration history, RLS, contracts, Edge Auth, pgTAP, benchmark, Consolidated Audit, and Demand Capture passed.

Rollback is forward-only: a future migration may repoint the existing bridge to the preserved private V1 oracle. Do not edit applied migrations or remove V1.

## Next objective

Keep PR #439 draft for human review. Do not merge. The next gate is review/approval of this controlled cutover; PR-05 remains unstarted.

## Do not do yet

- no merge
- no PR-05
- no tenant work
- no cache layer

## Resume instruction

A short instruction such as `continue pelo handoff` means: verify remote HEAD/CI first, then execute only the currently authorized objective in this file.
