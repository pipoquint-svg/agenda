# CURRENT HANDOFF — Agenda

## 2026-10-17 — rescheduling RPC security hotfix

User prioritized recording the production security correction in GitHub. Isolated
branch `fix/restrict-reschedule-rpc-20261017`, based on main `65bd6c3`.
Production migration `20261017092418_restrict_reschedule_internal_rpc_execute`
revoked public, anon and authenticated execution of the reschedule hold and
difference payment intent RPCs and retained service-role access. This branch
records that exact migration and adds explicit ACL regression assertions.
Production ACLs were previously verified; no production changes authorized by
this work. Clean local rebuild including the migration passed; all 177 pgTAP
files / 2,289 assertions passed, as did local security advisors at error level.
Next: review the diff, open a PR, and monitor CI on its actual HEAD.
The Rewards PR #495 referenced below is merged; leave its other work untouched.

## BlackSheep Rewards S1–S5 — active PR #495

Branch `feat/rewards-campaign-foundation-s1-20261014`, PR [#495](https://github.com/pipoquint-svg/agenda/pull/495), with the local Marketing publication commit ready to push. S3 is a private, service-role-only and read-only eligibility evaluation for a completed, paid BlackSheep rental. The legacy Agenda source bridge uses immutable appointment snapshots of operation scope and service type; legacy appointments without a snapshot fail closed. S4 adds `service_issue_marketing_campaign_coupon(uuid,uuid,text)`: a service-only, idempotent transactional issuer. It requires S3 eligibility, creates one customer-bound `SERVICE_ONLY` promotional coupon from the immutable published version, copies the checkbox-selected service scope, records one issuance ledger row, and writes `ISSUANCE_LINKED` audit evidence attributed to the admin who published that version. Campaign creation and versioning require a nonempty checkbox selection via `eligibility_rules.service_ids`; the typed version-service projection is immutable. S5 snapshots `validity_basis` on the issued coupon. Rewards with `BOOKING_CONFIRMATION` are accepted in pricing while the confirmation window remains valid even when the rental is later; a `BEFORE` confirmation guard rejects `MARKETING_CAMPAIGN_COUPON_EXPIRED_AT_CONFIRMATION` if that window closed after checkout. Legacy coupons retain `RENTAL_START` behavior, including their existing hold guards. The Gestão now exposes **Marketing** at `/gestao/marketing`: an authenticated `SERVICES_MANAGE` administrator can list BlackSheep campaigns, create the checkbox-scoped immutable first version and transition it through its existing S2 lifecycle; all reads and transitions are tenant-bound before the private RPC is called. The screen labels S6 as frozen: it neither creates delivery jobs nor calls Dracma, Meta or WhatsApp. Focused pgTAP: `172_marketing_campaign_eligibility_evaluator.test.sql` (36 assertions). Canonical CI was green at `e985a41` before this UI slice. Next objective: push the local commit, obtain green CI, then execute only the publication explicitly authorized by the user; S6 remains frozen and real campaign activation, issuance and delivery remain out of scope unless separately authorized.

## 2026-10-15 — Agenda → Dracma Messaging technical auto-provisioning

Current branch: `codex/agenda-auto-messaging-provisioning`.
Verification: `deno check` for the shared contract and proxy; focused signing
test 2/2 passed.

The user approved a no-duplicate-registration model: Agenda remains the identity
and company-system of record; its server can provision only the technical Dracma
Messaging projection after validating an authenticated admin with
`INTEGRATIONS_MANAGE`. The signed handoff now carries Agenda tenant UUID, admin
UUID, and company name. It never sends provider credentials, customers,
appointments, payments, or e-mail identity assertions.

The companion Dracma branch is `codex/agenda-auto-provisioning` and contains the
service-only idempotent provisioner. It creates no Messaging entitlement or
capability, so commercial-plan enablement remains an explicit Dracma decision.
Do not add a client-side direct call, infer users by e-mail, reactivate revoked
bindings, or open Meta as part of provision status.

## S0.5 coupon redemption lifecycle — requested 2026-10-14

Branch `fix/coupon-lifecycle-s05-20261014` from `origin/main` `f2600f4`. Commit,
push and PR to `main` authorized on 2026-10-14; merge, deploy, production
migrations and data correction are NOT authorized. No production access was
used. Forward-only, expand-only migration
`20261014203000_coupon_redemption_lifecycle.sql` with no data backfill:
redemption ledger on `appointment_discounts`, idempotent release, per-customer
limit ignores released redemptions, `coupons.discount_scope` (`ORDER_SUBTOTAL`
default keeps every existing coupon and the birthday automation unchanged;
`SERVICE_ONLY` excludes extras) in both pricing cores and both reschedule paths.
Tests: `169_coupon_redemption_lifecycle.test.sql` (65) and
`scripts/test-coupon-concurrency.sh` (added to Database Core). Local full pgTAP
172/2159 PASS, ACL/RLS overlays, concurrency and deploy gates PASS. Details,
consumption policy, residual risks and a read-only reconciliation query:
`docs/COUPON_REDEMPTION_LIFECYCLE_S05_2026-10-14.md`.

Conflicts to resolve before merge: open PR #471 (global rental-only coupons,
excludes additional people, patches the same functions) is mutually exclusive
with this slice and needs a user decision; PR #491 also sets absolute ACL
overlay counts, so whichever merges second must rebase and adjust them.

Next objective: confirm CI on the PR HEAD. Release requires separate
authorization (backup, then canonical production deploy, then read-only checks).
Do not start the BlackSheep Rewards engine (S1+).

## Notification variable catalog — explicitly authorized 2026-10-14

The user explicitly authorized `{{customer.phone}}` for notification templates.
This isolated slice adds the variable to the admin contract and supplies it to
customer appointment-confirmation and refund-completed email rendering. Legacy
variables remain supported by the backend and persisted templates; BlackSheep
hides the intentionally unused waitlist, employee/access, and refund-error
options only from the editor catalog. No provider, production configuration,
customer data, or live message is changed by this work.

Pending: review, separate Agenda and BlackSheep PRs, CI, and the normal
explicitly authorized publication gate. Rollback is a revert of either
independent PR; templates using legacy variables remain valid.

## WhatsApp tenant foundation — explicitly authorized 2026-10-15

Branch `codex/whatsapp-tenant-foundation` from `origin/main`
`a546f2dc9232caa4cee74d8d6e1627abf35ae5db`. This isolated additive foundation
reuses the canonical `tenants` record: it introduces tenant-bound Meta Cloud
identifiers and onboarding state (`whatsapp_tenant_integrations`), phone-number
identifiers (`whatsapp_tenant_phone_numbers`) and template-submission audit
state (`whatsapp_template_submissions`). The submission record is constrained to
the same tenant as its integration; WABA and provider phone IDs are globally
unique when present.

Forward-only migration: `20261015011437_whatsapp_tenant_foundation.sql`. Focused
database proof: `171_whatsapp_tenant_foundation.test.sql`; the reviewed
RLS-parity overlay explicitly records the three new closed tables. The tables
are RLS-enabled and closed to anon/authenticated roles; they store no
credentials or access tokens. This slice includes no Meta login, Embedded Signup
callback, Graph API call, webhook, template submission, activation, message
dispatch or production change. Rollback is a revert migration only before any
data is stored; no operational integration state exists yet.

Next objective: review and CI on the isolated PR. A subsequent adapter slice
requires explicit Meta setup/login authorization, a server-side
secret-management design, callback validation, action/audit contracts and
separate approval before any provider-facing mutation.

## WhatsApp delegated access projection — local slice 2026-10-15

The Agenda read model now includes a browser-safe WhatsApp integration
projection derived from the active authenticated admin's single explicit tenant
membership. It never guesses a tenant when the admin has zero or multiple active
memberships, and it returns no WABA, phone, credential, raw provider-error or
Dracma identifier. The corresponding BlackSheep UI explains that Dracma
administers the connection and only exposes a future connection action after the
server-side gateway reports it available.

Files: `supabase/functions/admin-integrations/index.ts`,
`supabase/functions/admin-integrations/whatsapp-contract.ts`, and its focused
Deno test. Verification: `deno check` passed and the focused contract test
passed 2/2. This is read-only and does not invoke Meta, create a Dracma
organization, create a membership, alter a provider, or make the Embedded Signup
popup available. The delegated bridge remains default-deny until a controlled
tenant/operator binding, a signed server-to-server assertion contract, secret
configuration, callback validation and deployment are separately implemented and
verified.

## Agenda → Dracma delegated WhatsApp signup — PR #498, 2026-10-15

PR `pipoquint-svg/agenda#498` exposes a narrow authenticated proxy for the
Dracma-owned Embedded Signup: authorized Agenda administrators can obtain
status, start a short-lived session, complete it or cancel it. The browser
receives no provider credential; the cross-project request is HMAC-signed and
Dracma resolves the tenant/operator binding server-side.
`admin-dracma-messaging` is declared as a `custom_admin` deployable function in
the auth contract, with `verify_jwt=false` because it validates the bearer token
and `INTEGRATIONS_*` permission inside the handler, matching
`admin-integrations`.

No deployment, provider configuration, Meta login, WABA/phone change, real
message, or production data mutation occurred. Dependencies: Dracma PR #703
before Agenda PR #498; BlackSheep PR #134 depends on both. Current next
objective: let current CI reach terminal state, correct only reproducible
contract failures, then obtain separate merge/publication authorization.

## Late checkout hold + shared admin session — explicitly requested 2026-10-12

**Published 2026-10-13.** Agenda PR #483 merged as
`70fa65a74ebf49cc574861314e6a24642b808457` (main CI green on that SHA). Backup
run 38402498564 produced protected artifact 11815977559 (5,667,866 bytes) before
the database step. Production deploy run 38403906439 applied migration
`20261012120000` and then failed only while bundling the Edge Function (ECR
`toomanyrequests`); run 38404795520 deployed `booking-checkout` from the same
SHA. Production readback without creating holds: `RELEASE` with an unknown token
returns `NOT_FOUND`; direct anon call to `service_public_release_checkout_hold`
returns 42501. BlackSheep PR #124 merged as
`bde4265bd9100a8210628d7259e3497e67c7a030`, synchronized by Lovable and
published (deployment `eb5924f8-38e2-4968-bc7f-71eabe524715`); the official
domain serves the late-hold booking code and the Gestão chunk without
"Verificando permissões…". The user confirmed both behaviors in production.
Pending: Sabrina embed upload to `sabrinapierri.com.br/agenda-native/` (outside
this repository's pipelines).

The user requested implementation, merge and publication. Branch
`feat/late-checkout-hold-admin-auth-20261012` in Agenda and in BlackSheep.
Details, contract and measurements:
`docs/LATE_CHECKOUT_HOLD_AND_ADMIN_SESSION_2026-10-12.md`.

- Forward-only migration `20261012120000_public_checkout_hold_release.sql` (one
  service-role RPC) plus `booking-checkout` action `RELEASE`. Release order:
  Agenda migration + `booking-checkout` deploy before the BlackSheep frontend
  (the frontend tolerates a missing `RELEASE`: the hold simply expires).
- The Sabrina embed bundle (`web/dist/embed`) is served from
  `sabrinapierri.com.br/agenda-native/`, outside this repository's pipelines;
  publishing it needs the site owner's upload step.
- Known unrelated: `165_post_booking_extras_dynamic_balance` fails after
  2026-10-05 (past-date fixture, open PR #473).

## Post-booking extras and dynamic balance — published 2026-10-05

Agenda [PR #469](https://github.com/pipoquint-svg/agenda/pull/469) merged as
`d3bb4008bf4c20716d418cb982b34fbabb8627de`. BlackSheep
[PR #117](https://github.com/pipoquint-svg/black-sheep/pull/117) merged as
`282b574d9f4ec0788b16edc82bdd5304acf7eb1b`. Both are published. The feature
consists of migration `20261005150444_post_booking_extras_dynamic_balance.sql`,
four affected Edge Functions, and the Gestão/payment UI. The prior magic PAY and
legacy collection/email paths remain in place.

- Before database deployment,
  [backup run 37343795196](https://github.com/pipoquint-svg/agenda/actions/runs/37343795196)
  produced a protected 3,678,559-byte logical artifact with SHA-256 digest
  `19787cc130bebdc6255ddae478573bdc6a266857e9c4d63f07e1354c61631538`, retained
  through 2026-10-12. The forward-only rollback path is documented in
  `POST_BOOKING_EXTRAS_2026-10-05.md`.
- [Agenda production run 37345679703](https://github.com/pipoquint-svg/agenda/actions/runs/37345679703)
  passed its exact-SHA gate, canonical database rebuild, migration dry run,
  migration apply, Edge auth contract and deployment of
  `admin-appointment-edit`, `balance-collection-provider-cancel`,
  `balance-collection-notify-email`, `mercado-pago-payment`. Main CI also
  passed. Production readback confirms the migration version, ledger table,
  RPCs, provider-refresh column and four active functions. The two internal
  functions reject unauthenticated calls with HTTP 401.
- Lovable synchronized the BlackSheep merge SHA and published it to
  `https://blacksheepestudiocriativo.com.br` (deployment
  `3304cecd-2037-4494-8c57-674765321ca5`). The official domain serves the new
  Gestão bundle, and `/pagar-saldo` plus `/reserva/saldo` return HTTP 200.
- BlackSheep PR checks passed QA, security, four integrated Gestão suites and
  smoke. The post-publication
  [workflow run 37349125380](https://github.com/pipoquint-svg/black-sheep/actions/runs/37349125380)
  passed QA, all integrated suites and final smoke on the merged main SHA. Its
  new browser E2E uses a disposable local reservation and original quote,
  launches two 30-minute extras, keeps one collection/token, and displays the
  updated balance without creating a PIX/card charge. Production ledger count
  remained zero during verification.
- The Supabase Preview check was skipped because two still-open PRs occupy the
  branch limit. The disposable local stack supplied the safe integrated preview.
  Provider cancellation was verified in database and adapter tests, not against
  a live Mercado Pago order. Existing unrelated local
  `supabase db lint --level error` reports missing `penalty_due_now` in
  `service_admin_create_reschedule_hold_unchecked`; main CI and deployment
  rebuild passed. No new security-advisor error was reported.

Next objective: monitor live operational errors and payment divergence records
as normal operations use the new flow. Do not create a real charge solely for
validation.

## Balance magic payment link hotfix — separately authorized on 2026-10-03

The user explicitly requested replacement of the manual email confirmation step
with a scoped magic payment link and authorized implementation plus publication.
This is an isolated payment-access security and UX correction; it does not
change financial rules.

- Agenda branch: `fix/magic-payment-link-20261003`; PR:
  `pipoquint-svg/agenda#466`; implementation HEAD before this handoff update:
  `ef4d978b0a0664d3668e2191cbb28e271e96c5c8`.
- BlackSheep branch: `fix/magic-payment-link-20261003`; PR:
  `pipoquint-svg/black-sheep#116`; HEAD:
  `a77938a46219f944bc0ce2e61632be2fa842ba39`.
- Forward-only migration: `20261003190846_balance_magic_payment_link.sql`.
- New email links use a 256-bit random secret in `#token=`, persist only its
  SHA-256 hash, carry PAY-only scope, inherit collection expiry, and are revoked
  on payment or superseding collection issuance. The browser removes the
  fragment immediately and never writes it to Web Storage or request URLs.
- `/reserva/saldo` and `/pagar-saldo` validate the magic token directly through
  the backend and open the authoritative FULL-balance PIX/card checkout without
  asking for email. Existing `?collection=<UUID>` links retain the previous
  collection-plus-email fallback during the transition.
- Focused verification completed: Deno helper tests 2/2; database pgTAP 17/17;
  Agenda web check/build; Edge type checks; BlackSheep payment tests 7/7, lint,
  typecheck, client build and SSR build; local clean database rebuild and
  security advisor error gate.
- The duplicated manual-booking migration that prevented any main-based
  canonical rebuild was removed independently in Agenda PR #467, merged as
  `4517ae5b05ee6ca5862f86f4e6c2f20fda92ebd7`. No runtime schema content was
  removed because the retained migration is byte-equivalent.
- Release order: merge Agenda PR #466 after final CI, deploy its migration plus
  `balance-collection-access` and `balance-collection-notify-email`, verify
  production without charging, then merge/publish BlackSheep PR #116 and verify
  both public routes. Do not claim live behavior before these checks finish.

## Invoice checkout hotfix — separately authorized on 2026-09-21

The user explicitly requested independent prebooking plus invoicing and normal
checkout for authorized invoice customers. This is an isolated production-bug
correction, not a change to PR-05's scope or authorization.

- Branch: `fix/invoice-prebook-checkout-20260921`.
- Agenda PR: #456. Functional code and regression fixture at
  `871a32e5c72850713edbcb3b44bf1adcb2d454d4`.
- BlackSheep frontend PR: `pipoquint-svg/black-sheep#113`, HEAD
  `bcd14729cf29943e11febeec50ae39dfa6df91ca`.
- Forward-only migration: `20260921210000_invoice_prebook_checkout.sql`.
- Verified: 42 focused invoice database assertions passed in run `35658214878`;
  invoice email tests passed. BlackSheep QA and all five Gestão suites passed in
  run `35657074689`.
- Current full Agenda database, ACL/RLS, concurrency, HTTP and browser gates
  must still be checked to terminal state on the actual PR HEAD. Native
  documentation commits create a new HEAD; do not mistake an earlier green run
  for final approval.
- No production schema, customer record, reservation, payment, or integration
  job was modified by this hotfix work. No PR has been merged or deployed.
  Preserve Volt reservation `31A0F1260B1B`.
- Exact next objective: verify current PR diff/HEAD and finish all required CI,
  fixing only real reproducible regressions. Then obtain/verify the release
  authorization and use the canonical deployment procedure: backend migration
  and five affected Edge Functions before both frontends. Do not claim live
  behavior until production version and non-charging smoke checks are verified.

The contractual flows, identity checks, invoice due-date basis, expiry behavior
and release sequence are documented in `docs/INVOICE_CHECKOUT_2026-09-21.md`.
Historical ACL goldens were not rewritten: historical schema and current schema
are verified separately, with explicit new-function privilege boundaries.

## Separate active work — PR-05 remains unchanged below

PR-05 — Tenant Foundation Branch: `codex/agenda-pr05-tenant-foundation` Base
main: `f6021d9fc816b174ec62e31f5a7ad66774e584e8`

PR-05 is authorized. Do not merge, do not deploy PR-05, and do not start PR-06.

## Completed before PR-05

PR-04 is merged and the monthly V2 engine is live in production. Production
smoke tests passed for BlackSheep and Sabrina. The public monthly endpoint
delegates to V2, V1 remains private as rollback oracle, ACLs are preserved, and
post-merge CI completed successfully.

Do not reopen PR-02/03/04 decisions in this PR.

## Gate 05-0 — migration history alignment

The three performance migrations were applied through the Supabase connector and
production recorded execution-time versions rather than the repository filename
versions.

Observed mapping:

- `20260913143607` -> `20260912130000_resolved_booking_base_context`
- `20260913143753` -> `20260912160000_month_availability_engine_v2`
- `20260913143801` -> `20260913110000_month_availability_v2_cutover`

Gate 05-0 passed on 2026-09-13 through
`.github/workflows/gate05-migration-history-repair.yml`. The supported CLI
workflow aligned the three canonical performance versions, reverted the five
verified remote-only entries, recorded `20260910164500`, `20260910213000`,
`20260912110500` as already applied after production evidence, and applied only
`20260912021000_add_sabrina_contextual_booking_pages.sql` after explicit
authorization and preflight.

The workflow ended with `supabase migration list --linked` aligned and
`supabase db push --linked --dry-run` successful. Production schema work in Gate
05-0 was limited to the authorized `20260912021000` migration.

## PR-05 objective

Create only the additive tenant foundation:

- `tenants`
- `tenant_members`
- `tenant_settings`
- `tenant_capabilities`

Do not add `tenant_id` broadly to existing domain tables yet. Do not change
public RPCs, frontend, booking, checkout, holds, Google sync runtime, finance,
availability, or `operation_settings.id=1` behavior. BASIC/ADVANCED behavior
remains deferred.

## Google Calendar — mandatory multitenant architecture constraint

The detailed decision now lives in this PR-05 branch at:
`docs/GOOGLE_SYNC_SCALABILITY_ARCHITECTURE_2026-09-13.md`.

PR-05 must preserve these rules:

- do not implement Amelia's fixed `2000 events` model literally;
- Google `events.list` is paginated: default 250 events/page, max 2500/page,
  with `nextPageToken` for continuation;
- current new-model Google Calendar quotas are 10,000 req/min per project, 600
  req/min per user/project, and a 1,000,000 req/day per-project billing
  threshold; older projects may retain earlier assigned quotas, so these are
  provider capacity inputs, not product guarantees;
- canonical flow is
  `Google Calendar -> bounded/paginated ingestion -> local materialization -> availability engine`;
- never enumerate thousands of remote events on every availability request;
- use bounded operational windows derived from booking horizon plus safety
  margin, not unbounded history;
- provider pagination cursor and incremental `sync_token` are different
  concepts;
- pagination is continuation, never silent truncation;
- internal page/event/runtime budgets are operational controls, not ordinary
  user settings;
- freshness and completeness are separate dimensions;
- Google-backed booking is safe only when the required interval is fresh enough
  and fully covered; PARTIAL/UNKNOWN/REBUILDING remains fail-closed;
- synchronization fairness must exist at global -> tenant -> connection/calendar
  levels;
- later runtime work needs idempotent/resumable jobs, backoff/jitter,
  observability and no synchronized full-sync bursts.

PR-05 records these constraints and creates tenant foundation only. It must NOT
rewrite the Google worker or add tenant ownership to existing Google tables yet.
That implementation belongs to the later integrations/jobs tenant gate after
core tenant ownership/security exist.

## Gate 05-A — inspect first

Audit the current canonical identity/RBAC schema before writing the migration.
Determine the existing authenticated user identity, current owner/admin
representation, current team/member tables, RLS patterns, and any existing
tenant-like objects. Reuse canonical identity rather than inventing a second
user system.

Document how existing BlackSheep owner/admin users can be bootstrapped into
tenant membership without changing current permissions.

Gate 05-A is complete. `docs/implementation/PR-05-RBAC-AUDIT.md` records that
`public.admin_users.auth_user_id` is the canonical Auth identity, with active
`OWNER`/`ADMIN` rows as the only bootstrap source. No tenant-like organization
table exists; `operation_scope` remains unrelated legacy domain context.

## Gate 05-B — foundation migration

After 05-A passes, create one forward-only additive migration for the four
tables.

Required invariants:

- tenant UUID primary key plus stable unique normalized slug/key;
- explicit tenant status/lifecycle with no runtime effect yet;
- `tenant_members` unique on `(tenant_id, user_id)` and one user may belong to
  multiple tenants;
- membership semantics must map cleanly to existing RBAC rather than conflict
  with it;
- `tenant_settings` at most one row per tenant;
- `tenant_capabilities` unique on `(tenant_id, capability_key)` with enabled
  state and optional config, but no plan enforcement;
- explicit timestamps/checks/FKs/supporting indexes;
- all four new tables RLS-enabled and closed by default to
  PUBLIC/anon/authenticated unless a proven runtime need exists;
- service-role administrative/bootstrap access remains explicit;
- no new tenant-selection SECURITY DEFINER helper unless Gate 05-A proves it is
  required.

Bootstrap exactly one current tenant for the BlackSheep operation using stable
canonical data. Backfill legitimate current owner/admin membership only from
existing canonical identity/RBAC records. Do not guess or hardcode generated
auth IDs. Keep bootstrap rebuild-safe and behavior-neutral.

## Gate 05-C — proof

Add focused tests proving:

- BlackSheep tenant bootstrap exists;
- tenant slug uniqueness/normalization;
- multi-tenant membership is allowed but duplicate same-tenant membership is
  rejected;
- one settings row per tenant;
- duplicate capability key per tenant is rejected;
- FK integrity;
- anon/authenticated cannot directly access the new tables;
- service-role boundary is explicit;
- existing monthly public endpoint still resolves through V2;
- existing critical booking/checkout tests remain green.

Run canonical rebuild and full authoritative CI. Push is not completion: monitor
every workflow to terminal state and fix reversible technical failures
autonomously.

## Deliverable

Open a draft PR titled approximately
`feat(agenda): add multi-tenant foundation`.

The PR body must state: additive foundation only; four tables; BlackSheep
bootstrap; Google multitenant constraints documented but Google runtime
unchanged; no domain tenant cutover; no public/frontend/runtime behavior change;
Gate 05-0 result; Gate 05-A findings; tests/CI; forward-only rollback; PR-06 out
of scope.

Update this handoff with branch, HEAD, migration, tests, CI and blockers.

## Stop conditions

Do not merge. Do not deploy PR-05. Do not start PR-06. Do not add tenant
ownership to existing domain tables. Do not rewrite Google sync runtime in this
PR. Do not add cache/Redis/Kafka/microservices/db-per-tenant/partitioning.

Stop only when PR-05 is published and authorized gates are green, or when a
genuine architecture/business decision requires human approval.

## Resume instruction

`Sincronize e continue pelo handoff` means: synchronize the remote branch first,
read `AGENTS.md` and this file, verify GitHub state, then execute the authorized
objective autonomously.
