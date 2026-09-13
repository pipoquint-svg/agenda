# Google Calendar Sync — Scalability and Completeness Architecture

Status: architecture decision for future implementation. This document does **not** change runtime behavior, production schema, booking rules, or the current PR-04 cutover.

## Context

The Agenda already materializes Google Calendar state locally through `google_calendars`, `google_sync_state`, `google_calendar_events`, `resource_allocations` and `schedule_divergences`.

The current booking safety model is intentionally fail-closed: a mapped resource is considered safe only when the Google connection is active and its sync is fresh enough. New hold/pre-reservation allocations are also blocked when Google state is not verifiably fresh.

That protects freshness, but future multi-tenant scale also requires a second invariant: **completeness of the synchronized interval**.

A provider-side event limit (for example, an integration UI that exposes a maximum number of returned events) must never be interpreted as proof that all relevant events were received.

## Decision

The Agenda will treat Google Calendar as an external ingestion source, not as the query engine used directly by booking availability.

Canonical direction:

`Google Calendar -> bounded/paginated ingestion -> local materialization -> availability engine`

The availability engine should read local authoritative scheduling state. It must not need to enumerate an unbounded remote calendar each time a customer opens a month.

## Core invariants

### 1. Every sync operation is bounded

Each worker execution must have explicit operational limits, such as:

- time window;
- maximum events/pages processed per run;
- execution-time budget;
- retry/continuation budget.

The exact numeric defaults are implementation details and should be measured. A value such as `2000` observed in another product is useful evidence that an upper bound is operationally necessary, but it is **not** adopted as an Agenda product requirement.

### 2. Pagination is continuation, not truncation

If Google indicates another page/token, or the Agenda stops because its own per-run budget was reached, the sync is incomplete.

The worker must persist continuation state and enqueue/resume another job. Reaching a local event/page limit must never mean "sync complete".

### 3. Freshness and completeness are different dimensions

`google_sync_state.health_status` currently represents states such as HEALTHY/STALE/ERROR/REBUILDING. Future synchronization must additionally represent whether the required operational interval is fully covered.

The design should distinguish at least:

- connection/provider health;
- last successful activity;
- freshness;
- synchronized interval/window;
- completeness of that interval;
- pending continuation/cursor state.

Do not overload `last_success_at` to mean complete coverage.

### 4. Booking is allowed only against verified coverage

For any Google-mapped resource used in a candidate booking range, the safety predicate must eventually become interval-aware:

- connection active;
- sync fresh enough;
- required booking interval lies inside a completely synchronized operational window;
- no unresolved provider state that invalidates confidence in that coverage.

If coverage is PARTIAL/UNKNOWN/REBUILDING for the required interval, booking must remain fail-closed for that mapped resource.

The current `google_resource_sync_is_ready(resource_id, max_age)` remains the existing safety gate until a separately parity-protected migration introduces interval completeness. Do not weaken it in place.

### 5. Local materialization remains the availability source

Remote blocking events should continue to become local scheduling facts, principally:

- `google_calendar_events` for normalized provider state;
- `resource_allocations` with `EXTERNAL_ACTIVE` for capacity blocking;
- `schedule_divergences` for conflicts that cannot be safely materialized.

Month/day availability should query these local facts rather than repeatedly call Google.

## Proposed state extension

Exact names are intentionally non-binding until implementation review. The future schema should be able to express concepts equivalent to:

- `coverage_window_start_at`;
- `coverage_window_end_at`;
- `coverage_status` (`COMPLETE`, `PARTIAL`, `UNKNOWN` or equivalent);
- continuation cursor/page token when applicable;
- `continuation_required`;
- `last_complete_sync_at`;
- current/rebuild generation identifier so stale partial generations cannot mark a newer rebuild complete.

The provider's incremental `sync_token` and an in-run pagination cursor are different concepts and should not be conflated.

## Full sync and incremental sync

### Initial/rebuild sync

A full or rebuild operation must use a bounded operational horizon rather than unbounded account history.

Example conceptually:

- a small past window needed for reconciliation;
- future horizon sufficient for the tenant's bookable horizon plus safety margin.

The actual window must be derived from Agenda booking requirements, not copied from another product.

The coverage status becomes COMPLETE only after every page covering that requested interval has been consumed and materialized successfully.

### Incremental sync

After a complete baseline exists, provider incremental tokens should be used where supported.

If an incremental token becomes invalid or provider state can no longer prove continuity:

1. mark the affected calendar as rebuilding/incomplete;
2. fail closed for mapped booking resources as required;
3. perform a new bounded baseline;
4. mark coverage complete only after all pages finish.

## Job execution model

A sync job should be idempotent and resumable.

Recommended unit of work:

`tenant -> Google connection/calendar -> requested coverage window -> page/chunk`

A run should:

1. acquire a lease/claim;
2. fetch one bounded page/chunk;
3. upsert normalized events idempotently;
4. apply/reconcile local allocations/divergences;
5. persist provider continuation state;
6. enqueue continuation when more work exists;
7. only mark the target window COMPLETE after the final page/chunk commits successfully.

A crashed worker must be able to resume without duplicate blocking allocations or false completeness.

## Multi-tenant fairness

When tenant foundations exist, synchronization capacity must be isolated/fair at three levels:

1. global worker budget;
2. per-tenant budget;
3. per-connection/calendar budget.

One tenant with a very large calendar must not monopolize all workers or delay sync for unrelated tenants.

Use short resumable chunks and queue continuation rather than one very long job.

Future `tenant_id` ownership must apply to Google connections, calendars, sync state, events, jobs, mappings and any derived operational state before external tenants are released.

## BASIC and ADVANCED capabilities

### BASIC

Typical shape:

- one professional/resource;
- one principal Google calendar;
- automatic operational window;
- hidden technical page/event limits;
- simple UI status such as "Sincronizado" / "Sincronizando" / "Precisa reconectar".

The user should not normally configure provider page sizes or maximum returned events.

### ADVANCED

Supports:

- multiple employees/resources;
- multiple Google accounts/calendars;
- independent sync state per mapping/calendar;
- richer diagnostics and operational visibility;
- tenant-safe prioritization of multiple sync lanes.

The same core completeness invariant applies to BASIC and ADVANCED.

## UI principle

Technical limits should generally remain internal.

Expose business-relevant state instead:

- synchronized and fresh;
- synchronization in progress;
- incomplete/rebuilding;
- reconnection required;
- last successful complete synchronization.

Never show a green/healthy booking state solely because a worker successfully processed N events if more pages remained.

## Observability

At minimum, operational telemetry should eventually support:

- events fetched per run;
- pages/chunks processed;
- continuations created;
- run duration;
- lag since last complete sync;
- partial/rebuilding duration;
- provider rate-limit/retry counts;
- number of calendars/resources currently fail-closed because coverage is incomplete;
- queue age by tenant/calendar.

These metrics are for capacity planning and alerting; they must not become user-configurable tuning knobs by default.

## Failure modes that must be covered by tests

Future implementation must test at least:

- page 1 succeeds, page 2 fails -> coverage remains incomplete;
- worker limit reached with next page available -> continuation required;
- process crashes after event upsert but before cursor commit -> idempotent recovery;
- duplicate page delivery -> no duplicate blocking allocations;
- invalid incremental token -> rebuild + fail-closed;
- reconnect after stale period -> no premature COMPLETE status;
- tenant A has huge calendar -> tenant B still progresses;
- event outside operational horizon -> does not cause unbounded ingestion;
- event added inside already-complete future window -> incremental sync materializes it before readiness can be considered current again;
- mapped resource with incomplete coverage -> no new unsafe hold.

## Relationship to current work

### PR-04

No scope change. PR-04 remains only the controlled public cutover of monthly availability V1 -> V2. Do not mix Google sync architecture changes into that PR.

### Tenant foundation

This document becomes an architectural constraint for tenant ownership and integrations. `operation_scope` and `booking_page_id` are not substitutes for tenant identity.

### Integration/jobs tenant work

When Google/integration tables and workers are made tenant-aware, completeness, continuation and fairness must be implemented or explicitly gated before allowing external multi-tenant booking against Google-mapped resources.

## Non-goals for the current phase

Do not add now solely because of this document:

- Redis;
- Kafka;
- a new microservice;
- provider polling on every booking request;
- an exposed "maximum Google events" setting for ordinary users;
- unbounded full-history synchronization;
- availability caching as a substitute for synchronization correctness.

## Acceptance rule for future implementation

A Google-backed resource is safe for booking only when the Agenda can prove that the local scheduling mirror is both **fresh enough and complete for the required booking interval**.

Fresh-but-partial is not safe.
