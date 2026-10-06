# CURRENT HANDOFF — Agenda

## Coupon rental-only pricing — 2026-10-06

The user requested that coupons discount only the rental hours and never extras. This is an isolated correction to the active Agenda pricing rules, separate from the tenant-foundation work below.

- [PR #471](https://github.com/pipoquint-svg/agenda/pull/471), branch: `fix/coupons-rental-only-20261006`; base: `a85c4e17aaf49f9a77e141f1fbc7ee1482c979b2`. Pricing implementation commit: `4efdf5cc25660cc43cd05697488383ec1693287e`.
- Migration: `20261006134927_coupons_rental_only.sql`. Fixed and percentage coupons share bounded arithmetic over rental plus day/time tariff, excluding catalog extras and positive additional-person charges. All three quote engines and direct coupon promotion use the rule.
- Persisted checkout coupons remain applied once. An old active snapshot with a discount that includes extras requires explicit coupon reapplication; it is never silently increased at payment submission. New appointment audits retain the agreed coupon scope.
- Both reschedule pricing paths retain rental-only scope for new contracts and preserve the original total-based scope of finalized legacy contracts. Original coupon validity/usage is not consulted or consumed again during rescheduling. Post-booking extras continue at their full separate price.
- [Database Core run 37475788999](https://github.com/pipoquint-svg/agenda/actions/runs/37475788999) passed on `04f33d8cbe678c1dc71850ea90e8128784850792`: 170 files and 2,136 assertions, including 42 focused pricing/promotion assertions, 32 reschedule assertions and the existing exactly-once/post-booking coverage. The canonical migration rebuild, current ACL overlay and remaining core gates also passed. Synthetic FIXED/confirmed/expired-hold fixtures respect the existing duration, policy and timestamp constraints. Two new helpers are SECURITY INVOKER and executable only by service_role; the current ACL overlay includes their exact identities/counts.
- The historical Item 2A workflow must park this migration before rebuilding its old baseline, then restore it before verifying current state. Its symmetric migration lists and path trigger now include the new file; historical golden inventories and assertions are unchanged. Final PR-HEAD CI is pending this workflow-fixture correction. No production change has been performed.
- Next objective: finish canonical isolated CI on the actual PR HEAD, publish only the pricing migration, verify actual database definitions and non-mutating quotes, and record the resulting PR/commit/deployment evidence here. Do not create customer reservations, send messages or create charges for verification.

## Post-booking extras and dynamic balance — published 2026-10-05

Agenda [PR #469](https://github.com/pipoquint-svg/agenda/pull/469) merged as `d3bb4008bf4c20716d418cb982b34fbabb8627de`. BlackSheep [PR #117](https://github.com/pipoquint-svg/black-sheep/pull/117) merged as `282b574d9f4ec0788b16edc82bdd5304acf7eb1b`. Both are published. The feature consists of migration `20261005150444_post_booking_extras_dynamic_balance.sql`, four affected Edge Functions, and the Gestão/payment UI. The prior magic PAY and legacy collection/email paths remain in place.

- Before database deployment, [backup run 37343795196](https://github.com/pipoquint-svg/agenda/actions/runs/37343795196) produced a protected 3,678,559-byte logical artifact with SHA-256 digest `19787cc130bebdc6255ddae478573bdc6a266857e9c4d63f07e1354c61631538`, retained through 2026-10-12. The forward-only rollback path is documented in `POST_BOOKING_EXTRAS_2026-10-05.md`.
- [Agenda production run 37345679703](https://github.com/pipoquint-svg/agenda/actions/runs/37345679703) passed its exact-SHA gate, canonical database rebuild, migration dry run, migration apply, Edge auth contract and deployment of `admin-appointment-edit`, `balance-collection-provider-cancel`, `balance-collection-notify-email`, `mercado-pago-payment`. Main CI also passed. Production readback confirms the migration version, ledger table, RPCs, provider-refresh column and four active functions. The two internal functions reject unauthenticated calls with HTTP 401.
- Lovable synchronized the BlackSheep merge SHA and published it to `https://blacksheepestudiocriativo.com.br` (deployment `3304cecd-2037-4494-8c57-674765321ca5`). The official domain serves the new Gestão bundle, and `/pagar-saldo` plus `/reserva/saldo` return HTTP 200.
- BlackSheep PR checks passed QA, security, four integrated Gestão suites and smoke. The post-publication [workflow run 37349125380](https://github.com/pipoquint-svg/black-sheep/actions/runs/37349125380) passed QA, all integrated suites and final smoke on the merged main SHA. Its new browser E2E uses a disposable local reservation and original quote, launches two 30-minute extras, keeps one collection/token, and displays the updated balance without creating a PIX/card charge. Production ledger count remained zero during verification.
- The Supabase Preview check was skipped because two still-open PRs occupy the branch limit. The disposable local stack supplied the safe integrated preview. Provider cancellation was verified in database and adapter tests, not against a live Mercado Pago order. Existing unrelated local `supabase db lint --level error` reports missing `penalty_due_now` in `service_admin_create_reschedule_hold_unchecked`; main CI and deployment rebuild passed. No new security-advisor error was reported.

Next objective: monitor live operational errors and payment divergence records as normal operations use the new flow. Do not create a real charge solely for validation.

## Balance magic payment link hotfix — separately authorized on 2026-10-03

The user explicitly requested replacement of the manual email confirmation step with a scoped magic payment link and authorized implementation plus publication. This is an isolated payment-access security and UX correction; it does not change financial rules.

- Agenda branch: `fix/magic-payment-link-20261003`; PR: `pipoquint-svg/agenda#466`; implementation HEAD before this handoff update: `ef4d978b0a0664d3668e2191cbb28e271e96c5c8`.
- BlackSheep branch: `fix/magic-payment-link-20261003`; PR: `pipoquint-svg/black-sheep#116`; HEAD: `a77938a46219f944bc0ce2e61632be2fa842ba39`.
- Forward-only migration: `20261003190846_balance_magic_payment_link.sql`.
- New email links use a 256-bit random secret in `#token=`, persist only its SHA-256 hash, carry PAY-only scope, inherit collection expiry, and are revoked on payment or superseding collection issuance. The browser removes the fragment immediately and never writes it to Web Storage or request URLs.
- `/reserva/saldo` and `/pagar-saldo` validate the magic token directly through the backend and open the authoritative FULL-balance PIX/card checkout without asking for email. Existing `?collection=<UUID>` links retain the previous collection-plus-email fallback during the transition.
- Focused verification completed: Deno helper tests 2/2; database pgTAP 17/17; Agenda web check/build; Edge type checks; BlackSheep payment tests 7/7, lint, typecheck, client build and SSR build; local clean database rebuild and security advisor error gate.
- The duplicated manual-booking migration that prevented any main-based canonical rebuild was removed independently in Agenda PR #467, merged as `4517ae5b05ee6ca5862f86f4e6c2f20fda92ebd7`. No runtime schema content was removed because the retained migration is byte-equivalent.
- Release order: merge Agenda PR #466 after final CI, deploy its migration plus `balance-collection-access` and `balance-collection-notify-email`, verify production without charging, then merge/publish BlackSheep PR #116 and verify both public routes. Do not claim live behavior before these checks finish.

## Invoice checkout hotfix — separately authorized on 2026-09-21

The user explicitly requested independent prebooking plus invoicing and normal checkout for authorized invoice customers. This is an isolated production-bug correction, not a change to PR-05's scope or authorization.

- Branch: `fix/invoice-prebook-checkout-20260921`.
- Agenda PR: #456. Functional code and regression fixture at `871a32e5c72850713edbcb3b44bf1adcb2d454d4`.
- BlackSheep frontend PR: `pipoquint-svg/black-sheep#113`, HEAD `bcd14729cf29943e11febeec50ae39dfa6df91ca`.
- Forward-only migration: `20260921210000_invoice_prebook_checkout.sql`.
- Verified: 42 focused invoice database assertions passed in run `35658214878`; invoice email tests passed. BlackSheep QA and all five Gestão suites passed in run `35657074689`.
- Current full Agenda database, ACL/RLS, concurrency, HTTP and browser gates must still be checked to terminal state on the actual PR HEAD. Native documentation commits create a new HEAD; do not mistake an earlier green run for final approval.
- No production schema, customer record, reservation, payment, or integration job was modified by this hotfix work. No PR has been merged or deployed. Preserve Volt reservation `31A0F1260B1B`.
- Exact next objective: verify current PR diff/HEAD and finish all required CI, fixing only real reproducible regressions. Then obtain/verify the release authorization and use the canonical deployment procedure: backend migration and five affected Edge Functions before both frontends. Do not claim live behavior until production version and non-charging smoke checks are verified.

The contractual flows, identity checks, invoice due-date basis, expiry behavior and release sequence are documented in `docs/INVOICE_CHECKOUT_2026-09-21.md`. Historical ACL goldens were not rewritten: historical schema and current schema are verified separately, with explicit new-function privilege boundaries.

## Separate active work — PR-05 remains unchanged below

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

Gate 05-0 passed on 2026-09-13 through `.github/workflows/gate05-migration-history-repair.yml`.
The supported CLI workflow aligned the three canonical performance versions, reverted the five verified remote-only entries, recorded `20260910164500`, `20260910213000`, `20260912110500` as already applied after production evidence, and applied only `20260912021000_add_sabrina_contextual_booking_pages.sql` after explicit authorization and preflight.

The workflow ended with `supabase migration list --linked` aligned and `supabase db push --linked --dry-run` successful. Production schema work in Gate 05-0 was limited to the authorized `20260912021000` migration.

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

Gate 05-A is complete. `docs/implementation/PR-05-RBAC-AUDIT.md` records that `public.admin_users.auth_user_id` is the canonical Auth identity, with active `OWNER`/`ADMIN` rows as the only bootstrap source. No tenant-like organization table exists; `operation_scope` remains unrelated legacy domain context.

## Gate 05-B — foundation migration

After 05-A passes, create one forward-only additive migration for the four tables.

Required invariants:
- tenant UUID primary key plus stable unique normalized slug/key;
- explicit tenant status/lifecycle with no runtime effect yet;
- `tenant_members` unique on `(tenant_id, user_id)` and one user may belong to multiple tenants;
- membership semantics must map cleanly to existing RBAC rather than conflict with it;
- `tenant_settings` at most one row per tenant;
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
