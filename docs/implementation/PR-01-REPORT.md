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

## CI validation

- Pull request: #436 (`test(agenda): add availability differential parity harness`).
- Validated head: `f658a84ae7d6024f5dea75c7c95fe423efbb1f13`.
- The first CI run executed 1,857 database tests and found two failures introduced solely by the new fixture's expected counts: legacy FIXED/BLOCKS produced 5/5 slots, not 4/3. Commit `f658a84` corrected only those expectations; no production rule, algorithm, migration or public contract changed.
- The validated rerun passed Database Core, canonical rebuild/Core DB, concurrency, ACL/RLS parity, negative/contract proofs, Edge auth contract, pgTAP plan, consolidated audit and Demand Capture. No pre-existing failure was found.

## Gate
**PASS.** CI is the authoritative validation environment because this workstation lacks the Supabase CLI/Docker runtime. The parity harness, full database gate and concurrency gate are green for the validated head. PR-02 remains blocked pending explicit authorization.
