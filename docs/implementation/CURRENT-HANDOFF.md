# CURRENT HANDOFF — Agenda

## Active PR

PR #438
Branch: `codex/agenda-pr03-month-engine-v2`

Gate 03-B validated HEAD before handoff files:
`13e6ca6a0762dfd83c4a040aec88501bae27dce7`

Handoff protocol commit:
`c44f6ddc73bcbdec66533e3ad8f0c191812d16c7`

Current PR rules:
- keep PR draft
- do not merge
- public monthly endpoint remains on V1
- do not start PR-04

## Completed

Gate 03-B: PASS.

The monthly V1 × V2 parity matrix is complete, including exceptions, occupancy, bounds, duration modes, extras/resource ranges, Google readiness/divergences, calendar shapes, and year boundary.

Required CI was green on the validated Gate 03-B HEAD.

## Current gate

Gate 03-C is not complete.

Current subgate: **Gate 03-C0 — benchmark infrastructure smoke test in GitHub Actions.**

The Codex host cannot run the local Supabase/Docker stack, but the repository `Database Core` workflow already proves that GitHub Actions can install Supabase CLI, start a disposable local stack, reset the database, and run PostgreSQL commands.

The pgTAP harness `158_monthly_availability_differential_harness.test.sql` is not a reusable benchmark seed because its data is rolled back. Build a dedicated benchmark fixture instead.

## Next objective

Create and validate only enough benchmark infrastructure to produce one real V1 vs V2 measurement in GitHub Actions.

Preferred files, reusing any correct partial local work if present:
- `.github/workflows/month-availability-benchmark.yml`
- `scripts/benchmark-month-availability-v2.sh`
- `scripts/benchmarks/month-availability-v2-fixture.sql`
- `scripts/benchmarks/month-availability-v2-benchmark.sql`

Requirements:
1. Use a disposable `ubuntu-latest` runner.
2. Follow the same Supabase setup pattern already used by `db-core.yml`.
3. Use only the runner-local PostgreSQL instance.
4. The benchmark fixture must be independent of pgTAP 158.
5. Fixture and timing queries must share the same database lifetime.
6. Before timing, compare the complete ordered monthly date set from V1 and V2; fail the benchmark on divergence.
7. Initial smoke scenario: a 31-day month with frequent availability.
8. Run 2 warmups per engine.
9. Run 7 measured samples per engine.
10. Calculate median, min, max, sample count, speedup, and parity.
11. Publish results in the GitHub Actions Step Summary; artifact output is preferred.
12. Do not use an arbitrary speed threshold in this smoke subgate.

## Gate 03-C0 PASS

PASS only when:
- the disposable database starts and migrations apply;
- the dedicated fixture applies;
- V1 executes;
- V2 executes;
- ordered-date parity passes;
- warmups execute;
- 7 V1 and 7 V2 measured samples exist;
- timing summary is calculated;
- GitHub Actions publishes the result;
- benchmark workflow succeeds;
- normal PR CI remains green;
- public endpoint still uses V1.

## Autonomous loop

Do not stop after creating files, pushing, or triggering Actions.

Monitor the new HEAD. If workflow, SQL, shell, YAML, or fixture validation fails, inspect the failure, make the smallest safe correction, push again, and continue monitoring until Gate 03-C0 passes or a genuine human decision is required.

## Do not do in Gate 03-C0

- no merge
- no public cutover
- no PR-04
- no broad engine refactor
- no final Gate 03-C performance conclusion yet

## On completion

Update this file with the latest HEAD, workflow result, parity, V1/V2 medians, speedup, CI status, and the exact next objective.
