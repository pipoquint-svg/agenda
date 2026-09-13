# PR-05 Gate 05-A — Canonical identity and RBAC audit

## Confirmed identity boundary

`public.admin_users` is the current administrative identity source. Its
`auth_user_id` is a unique FK to `auth.users(id)`; `role` and `is_active`
represent the existing application RBAC state. `public.admin_user_permissions`
is the per-admin permission override table.

The server-side resolver `public.service_admin_resolve_auth_user(uuid)` maps an
already-authenticated `auth.users` identity to an active `admin_users.id` and is
executable only by `service_role`. Direct administrator table access is not the
new tenant authorization surface.

## Existing security model

- `admin_users` has RLS enabled with the self-select policy based on
  `auth.uid() = auth_user_id`.
- `admin_user_permissions` has RLS enabled and is consumed through existing
  privileged administrative functions.
- Current admin roles are `OWNER`, `ADMIN`, `OPERATION`, and `FINANCE`.
- No `tenants`, `tenant_members`, or equivalent organization-membership table
  exists in the migration history.

## PR-05 bootstrap decision

The initial `blacksheep` tenant is stable seed data. Its memberships are derived
only from active `public.admin_users` rows with role `OWNER` or `ADMIN`, using
their existing `auth_user_id`; no Auth UUID is hardcoded and no second user
model is created. `OPERATION` and `FINANCE` are intentionally not backfilled as
tenant members in this foundation-only gate.

`operation_scope`, booking pages, and Google ownership fields are not tenants
and remain untouched. No tenant-selection function is needed before PR-07,
because the new tables are closed to `anon` and `authenticated` direct access.

## Evidence

- `supabase/migrations/20260821200000_google_runtime_security.sql`
- `supabase/migrations/20260822114000_admin_rbac.sql`
- `supabase/migrations/20260823043100_rls_and_fk_performance_hardening.sql`
- `supabase/migrations/20260828221500_admin_auth_user_resolver.sql`
