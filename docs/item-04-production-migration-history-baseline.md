# Item 4 — production migration-history baseline

## Why this follow-up exists

Production Deploy run `33749360739` reached the linked production database successfully, but `supabase db push --linked --dry-run` refused to continue because the historical rows in `supabase_migrations.schema_migrations` do not use the same version identifiers as the canonical files in `supabase/migrations`.

No schema migration was applied by that failed run.

The drift is historical and predates the mandatory production deploy gate:

- early migrations were recorded with execution-time versions while the original migration identity remained in `name`;
- `rc_bundle_01..05` and `rc_micro_01..13` grouped many canonical migrations into synthetic history rows;
- some production-only operational records were also written to the tracking table;
- the repository already contains at least one deliberate historical alias (`20260830220944_service_employee_range_anchor.sql`) created after a concurrent rollout.

This means the old history cannot safely be replayed against production. In particular, unrelated historical migrations touch catalog/pricing/Google/payment surfaces that are explicitly outside Item 4.

## Authoritative baseline

For this one-time reconciliation, the **current production schema is authoritative for all historical work through**:

`20260902214000_harden_service_role_execute_contracts.sql`

The next and only permitted pending migration is:

`20260902233000_retire_checkout_recovery_plaintext.sql`

Historical migrations are therefore tracked as already absorbed by production; they are not executed again.

## Audit evidence before reconciliation

Project: `sbexdggbwqvyhbkatucs`

Remote history before reconciliation:

- record count: `178`
- minimum version: `20260821160000`
- maximum version: `20260902224016`
- MD5 of sorted remote versions with final newline: `9073b0c44a6662a3af71d63388b36173`

The complete `version / name / statement-md5 / SQL-length` snapshot is versioned at:

`docs/audit/production-migration-history-2026-09-03.tsv`

The snapshot preserves audit evidence for synthetic/operational rows before their tracking identifiers are canonicalized.

## Reconciliation mechanism

`scripts/production_migration_history_baseline.py` uses only the official Supabase CLI migration-history operation:

`supabase migration repair`

That command changes migration tracking metadata only. It does **not** execute or revert migration SQL.

The reconciler is fail-closed:

1. requires the exact production project ref;
2. requires the committed 178-row history fingerprint;
3. requires the local migration sequence to end with Item 4 immediately after the baseline cutoff;
4. marks missing canonical historical versions as `applied` in tracking metadata;
5. then removes legacy/synthetic tracking versions not present in the canonical historical baseline;
6. supports resuming after a partial metadata operation, but accepts only the mathematically allowed initial/intermediate/final sets;
7. verifies that remote-only versions are zero and the **only** local-only version is Item 4.

Any unknown concurrent history state aborts before schema SQL is run.

## Production Deploy integration

`production-deploy.yml` keeps the existing exact-SHA, rebuild, dry-run and push gates. It adds one explicit boolean input:

`reconcile_migration_history`

Default: `false`.

For the one-time Item 4 production deployment it must be set to `true`, together with:

- `deploy_database=true`
- `deploy_edge_functions=false`

The order is mandatory:

1. exact-SHA validation;
2. full reusable DB rebuild;
3. link production;
4. one-time migration-history reconciliation;
5. verify only Item 4 is pending;
6. `supabase db push --linked --dry-run`;
7. `supabase db push --linked --yes`;
8. production smoke.

No `--include-all` is allowed.

## Scope protection

This follow-up does not alter application schema, product rules, pricing, availability, cancellation/reschedule, Google Calendar configuration, Mercado Pago configuration, Kommo, Guard, or Dracma.

It exists only to make the versioned production deploy gate capable of applying Item 4 without replaying historical migrations.
