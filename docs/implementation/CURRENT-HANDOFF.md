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

The supported CLI workflow has aligned those three mappings and, with explicit authorization, reverted five additional remote-only history entries:
`20260910220506`, `20260910224148`, `20260912110723`, `20260912131016`, and `20260912131034`.

No application schema was changed. The resulting dry-run is now blocked by four *local-only* migrations that precede the last remote migration:
`20260910164500_admin_agenda_google_event_display_id.sql`, `20260910213000_admin_customers_operation_scope.sql`, `20260912021000_add_sabrina_contextual_booking_pages.sql`, and `20260912110500_finance_launches_range.sql`.

Do not mark these local migrations applied, execute them, or use `--include-all` without explicit confirmation of their production-schema provenance. Gate 05-0 remains blocked pending that decision.

## PR-05 objective

Create only the additive tenant foundation:
- `tenants`
- `tenant_members`
- `tenant_settings`
- `tenant_capabilities`

Do not add `tenant_id` broadly to existing domain tables yet. Do not change public RPCs, frontend, booking, checkout, holds, Google sync runtime, finance, availability, or `operation_settings.id=1` behavior. BASIC/ADVANCED behavior remains deferred.

## Google Calendar — mandatory multitenant architecture constraint

The detailed decision now lives in this PR-05 branch at:
`docs/GOOGLE_SYNC_SCALABILITY_ARCHITECTURE_2026-09-13.md`.

PR-05 must preserve these rules:
- do not implement Amelia's fixed `2000 events` model literally;
- Google `events.list` is paginated: default 250 events/page, max 2500/page, with `nextPageToken` for continuation;
- current new-model Google Calendar quotas are 10,000 req/min per project, 600 req/min per user/project, and a 1,000,000 req/day per-project billing threshold; older projects may retain earlier assigned quotas, so these are provider capacity inputs, not product guarantees;
- canonical flow is `Google Calendar -> bounded/paginated ingestion -> local materialization -> availability engine`;
- never enumerate thousands of remote events on every availability request;
- use bounded operational windows derived from booking horizon plus safety margin, not unbounded history;
- provider pagination cursor and incremental `sync_token` are different concepts;
- pagination is continuation, never silent truncation;
- internal page/event/runtime budgets are operational controls, not ordinary user settings;
- freshness and completeness are separate dimensions;
- Google-backed booking is safe only when the required interval is fresh enough and fully covered; PARTIAL/UNKNOWN/REBUILDING remains fail-closed;
- synchronization fairness must exist at global -> tenant -> connection/calendar levels;
- later runtime work needs idempotent/resumable jobs, backoff/jitter, observability and no synchronized full-sync bursts.

PR-05 records these constraints and creates tenant foundation only. It must NOT rewrite the Google worker or add tenant ownership to existing Google tables yet. That implementation belongs to the later integrations/jobs tenant gate after core tenant ownership/security exist.

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
