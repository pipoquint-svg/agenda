# PR-02 Report — resolved stable booking context

## Baseline / matrix

`services`, active service-employee validation, contracted duration, service buffers, timezone and `operation_settings.id=1` are request-constant in `list_available_slots_for_duration_without_google_sync_gate`. Candidate start/end, extra schedule profile (it receives anchor start), occupied ranges, weekly/exception containment and all Google/divergence overlap checks are candidate-specific.

## Options considered

1. JSONB mega-context: rejected; weak typing and repeated extraction.
2. Composite type: rejected; would make the SQL path less transparent for one targeted reduction.
3. CTE: rejected; cannot be shared across PL/pgSQL candidate-loop function calls.
4. Small typed internal SQL helper: chosen. It receives already-resolved contracted duration and buffers, while computing candidate-dependent extra profile/ranges locally.

## Call graph / reduction

Before, each candidate/resource call entered `calculate_booking_resource_ranges_for_duration`, which reread `services` and called `resolve_service_contracted_minutes`. After, the duration engine resolves `v_service` and `v_contracted_minutes` once, then invokes `agenda_internal.calculate_booking_resource_ranges_resolved_duration` with them. Structural reduction confirmed: one service lookup/duration resolver per candidate-resource path was removed. Latency is not yet measured.

## Compatibility / Google / legacy

Public wrappers and signatures are unchanged. Google readiness/conflict/divergence remain outside this helper and candidate-specific. `operation_settings.id=1` remains LEGACY SINGLE-TENANT COMPATIBILITY and is not a tenant model.

## Deferred

Month-wide candidate generation and month V2 remain PR-03 only. No tenant, frontend, cache, HOLD or exclusion-constraint work is included.

## Tests / gate

Golden output must not be updated.

CI validation of implementation head `66a0d86` passed: Database Core (including the parity harness and concurrency gates), canonical rebuild, migration-history baseline, RLS parity, Edge Auth Contract, pgTAP plan, contract-and-negative-proofs, consolidated audit, and Demand Capture. No golden slot result was changed.

## Resource-range parity

The parity fixture compares complete normalized `(resource_id, occupied_range)` JSON arrays in deterministic order for service-only, PREPEND extra, APPEND extra, and a legitimate same-resource merge: both extras require the service studio, so the legacy and resolved paths must agree on `min(lower(range))` and `max(upper(range))`.

## Migration strategy

The targeted `pg_get_functiondef + replace` migration was chosen to keep the existing mature candidate loop intact. It replaces exactly the known legacy range call and fails explicitly if that text is absent. Canonical rebuild validates deterministic application against current history. Logical rollback is a forward-only migration restoring the prior call; applied history is never edited.

The existing static guards were updated from an obsolete literal-call/hash baseline to the intentional structural contract: the unchanged no-Google internal engine remains byte-for-byte pinned, while the duration engine must call the resolved helper with its already-resolved duration and service buffers. This does not relax behavioral parity; the parity harness compares the resulting slots and resource ranges.

## Performance statement

Structural reduction is confirmed: the resource-range path no longer rereads `services` or calls `resolve_service_contracted_minutes` per candidate. End-to-end latency improvement is not yet measured.
