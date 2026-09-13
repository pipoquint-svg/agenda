# Google Calendar Sync — Scalability and Completeness Architecture

Status: architecture decision for multi-tenant implementation. This document records constraints for PR-05 and later tenant-aware integration work. It does not by itself change Google runtime behavior.

## Provider facts verified on 2026-09-13

For the official Google Calendar API `events.list` method:

- default page size is 250 events;
- `maxResults` is capped at 2500 events per page;
- more results are exposed through pagination (`nextPageToken`).

The Google Calendar usage-limit documentation currently states, for projects subject to the newer quota model:

- 10,000 requests/minute per project;
- 600 requests/minute per user per project;
- 1,000,000 requests/day per project as the current daily billing threshold.

Google also states that some projects with API usage before the new model may keep previously assigned quotas. Therefore these figures are provider limits/capacity inputs, not product guarantees that should be hardcoded into Agenda behavior.

The Amelia-style `Maximum number of events returned` setting is therefore an implementation choice, not a Google API quota. Agenda will not adopt a literal fixed 2000-event product limit.

## Context

The Agenda already materializes Google Calendar state locally through `google_calendars`, `google_sync_state`, `google_calendar_events`, `resource_allocations` and `schedule_divergences`.

The current booking safety model is intentionally fail-closed: a mapped resource is considered safe only when the Google connection is active and its sync is fresh enough. New hold/pre-reservation allocations are also blocked when Google state is not verifiably fresh.

That protects freshness, but future multi-tenant scale also requires a second invariant: **completeness of the synchronized interval**.

A provider-side event limit must never be interpreted as proof that all relevant events were received.

## Decision

The Agenda will treat Google Calendar as an external ingestion source, not as the query engine used directly by booking availability.

Canonical direction:

`Google Calendar -> bounded/paginated ingestion -> local materialization -> availability engine`

The availability engine should read local authoritative scheduling state. It must not enumerate an unbounded remote calendar each time a customer opens a month or checks a date.

## Core invariants

### 1. Every sync operation is bounded

Each worker execution must have explicit operational limits, such as:

- time window;
- maximum pages/events processed per run;
- execution-time budget;
- retry/continuation budget.

Exact numeric defaults are implementation details to be measured. A value such as 2000 observed in another product is evidence that an operational bound is useful, but it is not an Agenda product requirement.

### 2. Pagination is continuation, not truncation

If Google returns a `nextPageToken`, or Agenda stops because its own execution budget was reached, synchronization is incomplete.

The worker must persist continuation state and enqueue/resume another job. Reaching a local page/event/time budget must never mean `sync complete`.

### 3. Freshness and completeness are different dimensions

`google_sync_state.health_status` currently represents provider/sync health states. Future synchronization must additionally represent whether the required operational interval is fully covered.

The design must distinguish at least:

- provider/connection health;
- last successful activity;
- freshness;
- synchronized interval/window;
- completeness of that interval;
- pending continuation/cursor state.

Do not overload `last_success_at` to mean complete coverage.

### 4. Booking is allowed only against verified coverage

For any Google-mapped resource used by a candidate booking, the safety predicate must eventually become interval-aware:

- connection active;
- sync fresh enough;
- required booking interval lies inside a completely synchronized operational window;
- no unresolved provider state invalidates confidence in that coverage.

If coverage is PARTIAL/UNKNOWN/REBUILDING for the required interval, booking remains fail-closed for that mapped resource.

The current `google_resource_sync_is_ready(resource_id, max_age)` remains the existing safety gate until a separately parity-protected migration introduces interval completeness. Do not weaken it in place.

### 5. Local materialization remains the availability source

Remote blocking events should continue to become local scheduling facts, principally:

- `google_calendar_events` for normalized provider state;
- `resource_allocations` with `EXTERNAL_ACTIVE` for capacity blocking;
- `schedule_divergences` for conflicts that cannot be safely materialized.

Month/day availability should query these local facts rather than repeatedly call Google.

## Proposed state extension

Exact names are intentionally non-binding until implementation review. Future schema should be able to express concepts equivalent to:

- `coverage_window_start_at`;
- `coverage_window_end_at`;
- `coverage_status` (`COMPLETE`, `PARTIAL`, `UNKNOWN` or equivalent);
- continuation cursor/page token when applicable;
- `continuation_required`;
- `last_complete_sync_at`;
- current/rebuild generation identifier so stale partial generations cannot mark a newer rebuild complete.

The provider's incremental `sync_token` and an in-run pagination cursor are different concepts and must not be conflated.

## Full sync and incremental sync

### Initial/rebuild sync

A full or rebuild operation must use a bounded operational horizon rather than unbounded account history.

Conceptually:

- a small past window needed for reconciliation;
- a future horizon derived from the tenant's bookable horizon plus safety margin.

The actual window must be derived from Agenda booking requirements, not copied from another product.

Coverage becomes COMPLETE only after every page covering the requested interval has been consumed and materialized successfully.

### Incremental sync

After a complete baseline exists, provider incremental tokens should be used where supported.

If an incremental token becomes invalid or provider state can no longer prove continuity:

1. mark the affected calendar as rebuilding/incomplete;
2. fail closed for mapped booking resources as required;
3. perform a new bounded baseline;
4. mark coverage complete only after every page finishes.

## Job execution model

A sync job must be idempotent and resumable.

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

A crashed worker must resume without duplicate blocking allocations or false completeness.

## Multi-tenant fairness

Synchronization capacity must be isolated/fair at three levels:

1. global worker budget;
2. per-tenant budget;
3. per-connection/calendar budget.

One tenant with a very large calendar must not monopolize workers or delay unrelated tenants. Prefer short resumable chunks plus continuation jobs rather than one long sync.

Future `tenant_id` ownership must apply to Google connections, calendars, sync state, events, jobs, mappings and derived operational state before external tenants are released.

## Rate limits and retry behavior

Provider quotas must be treated as shared infrastructure capacity, not as a per-tenant entitlement.

Later runtime work must include:

- truncated exponential backoff with jitter for quota/rate-limit failures;
- no synchronized full-sync bursts (for example, all tenants at midnight);
- queue/backpressure behavior when the provider throttles;
- tenant fairness even while one tenant is retrying heavily;
- provider quota values kept configurable/observable rather than hardcoded as business limits.

## BASIC and ADVANCED capabilities

### BASIC

Typical shape:

- one professional/resource;
- one principal Google calendar;
- automatic operational window;
- hidden technical page/event limits;
- simple UI state such as `Sincronizado`, `Sincronizando`, `Precisa reconectar`.

The user should not normally configure provider page sizes or maximum returned events.

### ADVANCED

Supports:

- multiple employees/resources;
- multiple Google accounts/calendars;
- independent sync state per mapping/calendar;
- richer diagnostics and operational visibility;
- tenant-safe prioritization of multiple sync lanes.

The same completeness invariant applies to BASIC and ADVANCED.

## UI principle

Technical limits remain internal by default. Expose business-relevant state instead:

- synchronized and fresh;
- synchronization in progress;
- incomplete/rebuilding;
- reconnection required;
- last successful complete synchronization.

Never show a healthy booking state solely because a worker successfully processed N events if more pages remained.

## Observability

Operational telemetry should eventually support at least:

- requests by project/user/tenant/calendar where measurable;
- events fetched per run;
- pages/chunks processed;
- continuations created;
- run duration;
- lag since last complete sync;
- partial/rebuilding duration;
- provider rate-limit/retry counts, including 429-class behavior;
- calendars/resources fail-closed because coverage is incomplete;
- queue age by tenant/calendar.

These metrics are for capacity planning and alerting; they must not become ordinary user-configurable tuning knobs.

## Failure modes that must be covered by tests

Future implementation must test at least:

- page 1 succeeds, page 2 fails -> coverage remains incomplete;
- worker budget reached with another page available -> continuation required;
- process crashes after event upsert but before cursor commit -> idempotent recovery;
- duplicate page delivery -> no duplicate blocking allocations;
- invalid incremental token -> rebuild + fail-closed;
- reconnect after stale period -> no premature COMPLETE status;
- tenant A has a huge calendar -> tenant B still progresses;
- event outside operational horizon -> no unbounded ingestion;
- event added inside already-complete future window -> incremental sync materializes it before readiness is considered current again;
- mapped resource with incomplete coverage -> no new unsafe hold.

## Relationship to PR-05 and later gates

PR-05 records this architecture as a mandatory multi-tenant constraint and creates only the tenant foundation (`tenants`, `tenant_members`, `tenant_settings`, `tenant_capabilities`). It does not rewrite Google runtime or spread `tenant_id` across existing integration tables.

When Google/integration tables and workers become tenant-aware in the later integrations/jobs tenant gate, completeness, continuation, bounded windows and fairness must be implemented or explicitly gated before external multi-tenant booking against Google-mapped resources is released.

`operation_scope` and `booking_page_id` are not substitutes for tenant identity.

## Non-goals for PR-05

Do not add solely because of this decision:

- Redis;
- Kafka;
- a new microservice;
- provider polling on every booking request;
- an exposed `maximum Google events` setting for ordinary users;
- unbounded full-history synchronization;
- availability caching as a substitute for synchronization correctness.

## Acceptance rule

A Google-backed resource is safe for booking only when Agenda can prove that the local scheduling mirror is both **fresh enough and complete for the required booking interval**.

Fresh-but-partial is not safe.