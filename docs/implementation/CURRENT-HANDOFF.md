# CURRENT HANDOFF — Agenda

## Active PR

PR #438
Branch: `codex/agenda-pr03-month-engine-v2`
Current benchmark-code HEAD: `0b7dd14` (documentation update pending CI).

Current PR rules:
- keep PR draft
- do not merge
- public monthly endpoint remains on V1
- do not start PR-04

## Completed

### Gate 03-B
PASS.

The monthly V1 × V2 parity matrix is complete, including exceptions, occupancy, bounds, duration modes, extras/resource ranges, Google readiness/divergences, calendar shapes, and year boundary.

### Gate 03-C — representative benchmark
PASS pending final documentation-head CI.

Authoritative GitHub Actions workflow `Month Availability V2 Benchmark`, run `34757040792`, succeeded on a GitHub-hosted Ubuntu runner using Supabase CLI 2.111.0 and disposable local Supabase/PostgreSQL. The dedicated fixture is transaction-scoped and rolls back after measurement.

Each scenario has ordered full-date V1/V2 parity, two warmups, and seven measured samples per engine. Median results: frequent 1046.270/243.210 ms (4.3019x), low 183.626/40.614 ms (4.5212x), zero 19.493/1.028 ms (18.9621x), resource-heavy 1041.971/236.905 ms (4.3983x), extras 1338.345/362.294 ms (3.6941x), occupancy 548.742/236.437 ms (2.3209x), all V1/V2 respectively. Google/divergence is not reliably timing-benchmarkable in the dedicated fixture; Gate 03-B provides its direct functional parity.

EXPLAIN is honestly limited to Function Scan for the PL/pgSQL entry point. The benchmark report contains the exact observable rows/timing/buffer values and names no index candidate.

Public endpoint still uses V1.

## Current gate

Gate 03-C is complete once the final documentation-only HEAD completes its CI green.

## Next objective

Monitor the final documentation-only push to green; then update the PR body with the validated 03-C summary and keep the PR draft for human review. Do not merge or cut over.

## Do not do yet

- no merge
- no public cutover
- no PR-04
- no tenant work
- no cache layer

## Resume instruction

A short instruction such as `continue pelo handoff` means: verify remote HEAD/CI first, then execute only the currently authorized objective in this file.
