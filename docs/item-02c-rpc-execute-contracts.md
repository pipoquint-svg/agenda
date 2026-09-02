# Item 2C — RPC EXECUTE contracts (#371)

## Scope

Item 2C removes direct `service_role` execution of five sensitive `SECURITY DEFINER` primitives. It does not change function bodies, RLS, table grants, Google Calendar configuration, Mercado Pago configuration, service configuration, or rental business rules.

## Production state proven before the change

The following five current production identities are owned by `postgres`, are `SECURITY DEFINER`, are not executable by `anon`/`authenticated`, and were executable by `service_role`:

- `service_admin_upsert_change_policy(uuid,jsonb)`
- `service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer)`
- `service_admin_replace_duration_configuration(uuid,jsonb,jsonb)`
- `maintenance_purge_audit_logs(timestamptz,text,text)`
- `maintenance_purge_appointment_token_network_evidence(timestamptz,text,text)`

The administrative runtime uses the three audited wrappers below instead of the three mutation primitives. They remain owned by `postgres`, `SECURITY DEFINER`, executable by `service_role`, and unavailable to `anon`/`authenticated`:

- `service_admin_upsert_change_policy_audited(uuid,jsonb,uuid)`
- `service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid)`
- `service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid)`

No `pg_cron` job or recent operational evidence was found for the two maintenance purge primitives. Historical attempt visibility is limited because PostgreSQL function tracking is not an authoritative complete history; this is not evidence that the functions were never invoked.

Before Item 2C, production has 414 `public` functions and 365 of them are executable by `service_role`. The intentional post-2C count is 360: exactly five EXECUTE privileges are removed.

## Versioned change

`20260902214000_harden_service_role_execute_contracts.sql` performs only five exact `REVOKE EXECUTE ... FROM service_role` statements. No permissive replacement grant or policy is introduced.

Item 2A remains the historical ACL baseline. `tests/acl-parity/item02c_acl_overlay.sql` proves the intentional post-baseline delta: five primitives closed, three audited wrappers preserved, no `anon`/`authenticated` exposure, identities/owners/security mode unchanged, and exact aggregate function counts.

## Automated failure-before / pass-after proof

Before the migration the dedicated gate requires exactly six named pgTAP failures from tests 027, 039, 042 and 050, plus `ITEM02C_PRIMITIVE_STILL_EXECUTABLE` from the ACL overlay. Any seventh/different failure is fatal.

After the migration all four target tests must be fully green, the overlay must emit `ITEM02C_ACL_OVERLAY_OK`, and the complete database test contract must have zero expected-failure quarantine.

## Production smoke and rollback

After merge and versioned production apply, read-only smoke must prove all five primitives are no longer executable by `service_role`, all three audited wrappers remain executable by it, `anon`/`authenticated` remain denied, the `public` function count remains 414 and the service-role executable count is 360. The Item 2B RLS state must remain unchanged.

If production smoke fails, stop. Rollback must be a new versioned migration that re-grants only the proven necessary function identity or identities; do not use ad-hoc production DDL and do not broaden privileges.
