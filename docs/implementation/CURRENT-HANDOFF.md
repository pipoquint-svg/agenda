# CURRENT HANDOFF — Agenda

## Production state — PR-05 Tenant Foundation

PR-05 is merged to `main`. The additive tenant-foundation migration
`20260913190000_tenant_foundation.sql` was applied to production project
`sbexdggbwqvyhbkatucs` by the controlled deploy workflow run `34847557305`.
No other migration was applied by that deploy.

### Post-deploy read-only validation — PASS

The dedicated production workflow run `34853174450` completed successfully on
`main` commit `2701d0f`. It used `supabase link --project-ref
sbexdggbwqvyhbkatucs` and a `BEGIN READ ONLY` validation query; it made no
schema or data changes.

Verified evidence:

- exactly one tenant has slug `blacksheep`;
- exactly one `tenant_settings` row belongs to that tenant;
- active tenant membership count is one and exactly matches the one active
  `admin_users` `OWNER`/`ADMIN` row through `auth_user_id`;
- no expected memberships are missing and no extra active or inactive
  memberships exist;
- no membership is sourced from `OPERATION` or `FINANCE`;
- RLS is enabled on `tenants`, `tenant_members`, `tenant_settings`, and
  `tenant_capabilities`;
- anonymous and authenticated direct selects are denied for all four tables;
- explicit `service_role` CRUD grants remain present for all four tables;
- remote migration history records `20260913190000` as applied.

The workflow artifact `tenant-foundation-production-validation` contains the
non-PII aggregate evidence and linked migration history.

## Completed before PR-05

PR-04 is merged and the monthly V2 engine is live. The public monthly endpoint
delegates to V2; V1 remains private as the rollback oracle. Public ACLs and
contracts were preserved.

## Next authorized preparation — PR-06 Tenant Core Ownership

Do **not** implement PR-06 until explicitly authorized. When authorized, begin
from current `origin/main`, inspect the actual core-domain ownership graph, and
add tenant ownership incrementally using forward-only, additive migrations.

Initial PR-06 scope is limited to the core entities named in the implementation
plan: services, categories, employees, resources, booking pages, customers,
appointments, checkout holds, availability rules/exceptions, resource
availability rules, and the necessary associative tables. Preserve existing
public contracts and do not trust a browser-provided tenant identifier.

Do not remove legacy columns, change booking/hold behavior, alter Google sync
runtime, or start tenant authorization/RLS enforcement for existing domain
tables in PR-06. Those are later gates.

## Resume instruction

`Sincronize e continue pelo handoff` means: safely synchronize the current
branch with its remote counterpart, read `AGENTS.md` and this file, then work
only within the explicitly authorized scope.
