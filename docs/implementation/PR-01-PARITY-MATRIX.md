# PR-01 parity matrix

The harness in `157_availability_parity_harness.test.sql` emits a canonical JSON envelope: normalized Sao Paulo local slot fields, duration, buffers, value, exact input, slot count and elapsed milliseconds. `elapsed_ms` is explicitly excluded from equality. PR-03 will add V2 as a second engine and compare `slots`/input/error envelope exactly.

| Required behavior | Existing trusted coverage | PR-01 capture status |
|---|---|---|
| FIXED, employee, resource, buffers, slots | 004, 010, 133 | executable golden fixture |
| BLOCKS and MINUTES | 023, 024, 025, 063, 099 | executable golden fixture |
| extras / duration-changing extras / people | 010, 062 | mapped; add golden case before V2 cutover |
| notice, rules, OPEN/CLOSE, holiday/special date | 123, 138, 139, 140 | mapped |
| Google block/stale/divergence | 013, 061, 101 | mapped |
| active/expired hold, appointment/cancel/reschedule | 004, 007, 015, 029, 031, 057 | mapped |
| day/month/year boundaries and America/Sao_Paulo | 079, 133 | mapped; month differential added in PR-03 |
| public/admin concurrent selection | 004 plus `scripts/test-concurrency.sh` | mapped; execute in Docker gate |

The matrix intentionally does not claim a V2 comparison before V2 exists. Every mapped row becomes an exact golden/V2 differential fixture in PR-03/04; no engine behavior is changed in PR-01.
