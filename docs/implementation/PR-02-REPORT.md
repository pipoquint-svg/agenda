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

Pending parity harness, Database Core and CI. Golden output must not be updated.
