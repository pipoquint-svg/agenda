# PR-01 Report — Golden Master / Parity Harness

## Objective
Add deterministic, serializable legacy availability captures without changing any availability algorithm or public contract.

## Changes
- Added a transaction-scoped pgTAP canonicalizer for FIXED, BLOCKS and MINUTES legacy engines.
- Added deterministic fixture captures including Sao Paulo normalized timestamps, slots, price, duration and buffers; volatile elapsed time is reported but excluded from equality.
- Added a traceable matrix mapping the requested behavioral coverage to existing trusted tests and the future V2 differential work.

## Files / migrations
- `supabase/tests/database/157_availability_parity_harness.test.sql`
- `docs/implementation/PR-01-PARITY-MATRIX.md`
- `docs/implementation/PR-01-REPORT.md`
- No migration. No production behavior change.

## Tests and metrics
Run `supabase test db` and `bash scripts/test-concurrency.sh` in a Docker-enabled local environment. The harness reports `elapsed_ms`, input, `slot_count`, and canonical slot JSON. It does not use volatile timestamps in equality.

## Risks / compatibility / rollback
Test-only objects are created inside a transaction and rolled back. Rollback is removal of these three files. Public APIs, holds and resource allocations are untouched.

## Gate
**Pending CI rerun.** Local execution remains unavailable: `supabase test db` failed before test execution because the CLI is not installed (`command not found`); `npm` is also absent and `pnpm` was blocked while preparing dependencies outside the permitted filesystem. CI initially ran 1,857 database tests and identified two harness-only expected-count errors (actual legacy counts were 5/5, not 4/3); the expectations were corrected without touching production SQL. PASS requires the rerun of the full database suite, `scripts/test-concurrency.sh`, and this harness green. Do not start PR-02 until that gate is recorded PASS.
