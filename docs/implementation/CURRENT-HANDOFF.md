# CURRENT HANDOFF — Agenda

## Active work

PR-05 — Tenant Foundation
Branch: `codex/agenda-pr05-tenant-foundation`
Base main: `f6021d9fc816b174ec62e31f5a7ad66774e584e8`

PR-05 is authorized. Do not merge, do not deploy PR-05, and do not start PR-06.

## Completed before PR-05

PR-04 is merged and the monthly V2 engine is live in production. Production smoke tests passed for BlackSheep and Sabrina. The public monthly endpoint delegates to V2, V1 remains private as rollback oracle, ACLs are preserved, and post-merge CI completed successfully.

Do not reopen PR-02/03/04 decisions in this PR.

## Gate 05-0 — migration history alignment

The three performance migrations were applied through the Supabase connector and production recorded execution-time versions rather than the repository filename versions.

Observed mapping:
- `20260913143607` -> `20260912130000_resolved_booking_base_context`
- `20260913143753` -> `20260912160000_month_availability_engine_v2`
- `20260913143801` -> `20260913110000_month_availability_v2_cutover`

Before creating any PR-05 migration, use the supported Supabase CLI migration-history repair workflow to align remote history with the canonical repository versions. Verify actual CLI syntax/version first. Then prove with migration-list plus a dry-run/preview that PR-02/03/04 would not be replayed.

Do not change application schema during Gate 05-0. If actual remote history differs from the mapping above, stop and report instead of guessing.

## PR-05 objective

Create only the additive tenant foundation:
- `tenants`
- `tenant_members`
- `tenant_settings`
- `tenant_capabilities`

Do not add `tenant_id` broadly to existing domain tables yet. Do not change public RPCs, frontend, booking, checkout, holds, Google sync runtime, finance, availability, or `operation_settings.id=1` behavior. BASIC/ADVANCED behavior remains deferred.

## Google Calendar — mandatory multitenant architecture constraint

PR-05 must record and preserve the following architecture decisions. Do not implement Amelia's fixed `2000 events` model literally and do not expose a user-facing `maximum Google events` setting.

Verified provider facts as of 2026-09-13:
- Google Calendar `events.list` returns 250 events per page by default;
- `maxResults` is capped at 2500 events per page;
- additional results require pagination via `nextPageToken`;
- the new Google Calendar quota model documents 10,000 requests/minute per project, 600 requests/minute per user per project, and a 1,000,000 requests/day per-project billing threshold;
- Google notes that some projects with earlier API usage may remain on previously assigned quotas, so actual project quotas must be treated as provider configuration, not hardcoded product guarantees.

Canonical direction:

`Google Calendar -> bounded/paginated ingestion -> local materialization -> availability engine`

Hard requirements for later Google tenant implementation:
- never enumerate thousands of remote events on every availability request;
- availability remains local-first, using materialized Google state;
- use bounded operational windows derived from the bookable horizon plus safety margin, not unbounded calendar history;
- distinguish provider pagination cursor from incremental `sync_token`;
- pagination is continuation, never silent truncation;
- internal per-run budgets may include pages, events and runtime, but exact values are operational/configurable internals rather than product limits;
- if a run stops before consuming all required pages, coverage is `PARTIAL`/incomplete and continuation must be persisted/enqueued;
- freshness and completeness are separate dimensions;
- Google-backed booking is safe only when the required interval is both fresh enough and fully covered; partial/unknown/rebuilding coverage remains fail-closed;
- synchronization work must be fair at global -> tenant -> connection/calendar levels so one large tenant cannot monopolize workers;
- retry rate limits with truncated exponential backoff/jitter and avoid synchronized full-sync bursts;
- preserve idempotent/resumable jobs and local materialization through existing Google event/allocation/divergence structures;
- track observability needed for capacity planning: requests, pages/events, continuation count, sync lag, partial duration, 429/rate-limit retries, queue age and fail-closed resources by tenant/calendar.

Existing architecture PR #440 contains the detailed documentation for these rules. Incorporate that document into this PR-05 branch (cherry-pick or equivalent), update it with the verified Google pagination/quota facts above, and then close/supersede PR #440 so there is one canonical change path.

Important scope boundary: PR-05 defines tenant identity/foundation and records these Google constraints. It must NOT rewrite the Google worker or add tenant ownership to existing Google tables yet. The runtime tenant-scope/worker implementation remains for the later integrations/jobs tenant gate after core tenant ownership/security are established.

## Gate 05-A — inspect first

Audit the current canonical identity/RBAC schema before writing the migration. Determine the existing authenticated user identity, current owner/admin representation, current team/member tables, RLS patterns, and any existing tenant-like objects. Reuse canonical identity rather than inventing a second user system.

Document how existing BlackSheep owner/admin users can be bootstrapped into tenant membership without changing current permissions.

## Gate 05-B — foundation migration

After 05-A passes, create one forward-only additive migration for the four tables.

Required invariants:
- tenant UUID primary key plus stable unique normalized slug/key;
- explicit tenant status/lifecycle with no runtime effect yet;
- `tenant_members` unique on `(tenant_id, user_id)` and one user may belong to multiple tenants;
- membership semantics must map cleanly to existing RBAC rather than conflict with it;
- `tenant_settings` at most one row per tenant and only foundation-level settings;
- `tenant_capabilities` unique on `(tenant_id, capability_key)` with enabled state and optional config, but no plan enforcement;
- explicit timestamps/checks/FKs/supporting indexes;
- all four new tables RLS-enabled and closed by default to PUBLIC/anon/authenticated unless a proven runtime need exists;
- service-role administrative/bootstrap access remains explicit;
- no new tenant-selection SECURITY DEFINER helper unless Gate 05-A proves it is required.

Bootstrap exactly one current tenant for the BlackSheep operation using stable canonical data. Backfill legitimate current owner/admin membership only from existing canonical identity/RBAC records. Do not guess or hardcode generated auth IDs. Keep bootstrap rebuild-safe and behavior-neutral.

## Gate 05-C — proof

Add focused tests proving:
- BlackSheep tenant bootstrap exists;
- tenant slug uniqueness/normalization;
- multi-tenant membership is allowed but duplicate same-tenant membership is rejected;
- one settings row per tenant;
- duplicate capability key per tenant is rejected;
- FK integrity;
- anon/authenticated cannot directly access the new tables;
- service-role boundary is explicit;
- existing monthly public endpoint still resolves through V2;
- existing critical booking/checkout tests remain green.

Run canonical rebuild and full authoritative CI. Push is not completion: monitor every workflow to terminal state and fix reversible technical failures autonomously.

## Deliverable

Open a draft PR titled approximately `feat(agenda): add multi-tenant foundation`.

The PR body must state: additive foundation only; four tables; BlackSheep bootstrap; Google multitenant constraints documented but Google runtime unchanged; no domain tenant cutover; no public/frontend/runtime behavior change; Gate 05-0 result; Gate 05-A findings; tests/CI; forward-only rollback; PR-06 out of scope.

Update this handoff with branch, HEAD, migration, tests, CI and blockers.

## Stop conditions

Do not merge. Do not deploy PR-05. Do not start PR-06. Do not add tenant ownership to existing domain tables. Do not rewrite Google sync runtime in this PR. Do not add cache/Redis/Kafka/microservices/db-per-tenant/partitioning.

Stop only when PR-05 is published and authorized gates are green, or when a genuine architecture/business decision requires human approval.

## Resume instruction

`Sincronize e continue pelo handoff` means: synchronize the remote branch first, read `AGENTS.md` and this file, verify GitHub state, then execute the authorized objective autonomously.