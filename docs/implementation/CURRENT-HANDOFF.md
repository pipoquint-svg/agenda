# CURRENT HANDOFF — Agenda

## Active PR

PR #438
Branch: `codex/agenda-pr03-month-engine-v2`
Current validated HEAD before this handoff update: `ec25f99339d9cb61413ba6bd97aeb2883191cee7`

Current PR rules:
- keep PR draft
- do not merge
- public monthly endpoint remains on V1
- do not start PR-04

## Completed

### Gate 03-B
PASS.

The monthly V1 × V2 parity matrix is complete, including exceptions, occupancy, bounds, duration modes, extras/resource ranges, Google readiness/divergences, calendar shapes, and year boundary.

### Gate 03-C0 — benchmark infrastructure smoke test
PASS.

Authoritative GitHub Actions run:
- workflow: `Month Availability V2 Benchmark`
- run id: `34754971151`
- result: SUCCESS
- environment: GitHub-hosted Ubuntu runner + Supabase CLI 2.111.0 + disposable local Supabase/PostgreSQL

Smoke benchmark scenario:
- scenario: frequent availability, 31-day month
- iterations: 7 measured samples per engine after warmup
- parity: PASS
- V1 median: 686.795 ms
- V2 median: 138.583 ms
- speedup: 4.9558387392393x
- V1 min/max: 681.419 / 699.532 ms
- V2 min/max: 134.855 / 143.227 ms

EXPLAIN for V2 smoke run:
- Function Scan on `list_available_dates_month_v2`
- rows: 31
- execution time: 134.048 ms
- shared buffers hit: 15697

Artifacts were published successfully in the benchmark workflow.

Normal PR CI on HEAD `ec25f99339d9cb61413ba6bd97aeb2883191cee7` is fully green, including Database Core, Migration History, RLS, Edge Auth, pgTAP, Consolidated Audit, Demand Capture, and Mandatory Deploy Gate.

Public endpoint still uses V1.

## Current gate

Gate 03-C overall is NOT complete yet.

Only the benchmark infrastructure smoke subgate (03-C0) is complete.

## Next objective

Await explicit authorization before expanding Gate 03-C to representative benchmark scenarios such as:
- low availability
- zero availability
- resource-heavy
- PREPEND/APPEND extras
- occupancy
- Google/divergence only if deterministic

Then complete benchmark analysis, EXPLAIN evidence, largest remaining cost, PR-03 report update, and final Gate 03-C decision.

## Do not do yet

- no merge
- no public cutover
- no PR-04
- no tenant work
- no cache layer

## Resume instruction

A short instruction such as `continue pelo handoff` means: verify remote HEAD/CI first, then execute only the currently authorized objective in this file.
