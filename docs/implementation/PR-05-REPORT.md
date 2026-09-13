# PR-05 — Tenant Foundation

## Objective

Add the organization root required for future multitenancy without changing
existing domain ownership, booking behavior, public RPCs, Google runtime, or
`operation_settings.id = 1` legacy behavior.

## Gate 05-0

Passed through the controlled GitHub Actions workflow. History reconciliation
recorded three evidenced pre-applied migrations and applied only the explicitly
authorized `20260912021000_add_sabrina_contextual_booking_pages.sql`. The final
linked migration list and dry-run were successful.

## Gate 05-A

`public.admin_users.auth_user_id` is the canonical authenticated identity;
active `OWNER` and `ADMIN` rows are the only bootstrap source. See
`PR-05-RBAC-AUDIT.md` for evidence. No second user system or tenant-selection
function is introduced.

## Changes

- `tenants`: normalized unique slug, lifecycle status, timestamps.
- `tenant_members`: Auth-user membership with per-tenant role/status and a
  uniqueness boundary on `(tenant_id, user_id)`.
- `tenant_settings`: one foundation-level JSON object per tenant.
- `tenant_capabilities`: normalized per-tenant capability key, enabled state,
  and JSON configuration.
- Stable `blacksheep` bootstrap tenant, settings row, and idempotent membership
  backfill from active canonical `OWNER`/`ADMIN` identities only.

## Security and compatibility

All four relations have RLS enabled and no direct `PUBLIC`, `anon`, or
`authenticated` privileges. `service_role` access is explicit. There is no
tenant selection RPC, no domain `tenant_id`, and no behavior cutover in this PR.

## Migration

`20260913190000_tenant_foundation.sql` is forward-only and additive. Logical
rollback is a later forward-only migration; no historical migration is edited.

## Tests and gate

`159_tenant_foundation.test.sql` proves bootstrap presence, normalized/unique
keys, membership uniqueness and multi-membership, settings/capability
constraints, FK integrity, RLS/ACL closure, explicit service-role access, and
the existing public monthly V2 seam. Local Supabase is unavailable on this host;
authoritative canonical rebuild and database gates run in GitHub Actions.

## Deferred

PR-06 ownership columns, PR-07 tenant authorization/RLS policies, Google
runtime ownership, capability enforcement, and all BASIC/ADVANCED behavior.
