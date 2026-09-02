#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
deploy_workflow='.github/workflows/production-deploy.yml'
db_core_workflow='.github/workflows/db-core.yml'
migration='supabase/migrations/20260902214000_harden_service_role_execute_contracts.sql'
overlay='tests/acl-parity/item02c_acl_overlay.sql'

for file in "$deploy_workflow" "$db_core_workflow" "$migration" "$overlay"; do
  test -f "$file"
done

# Static deployment contract: production has one explicit manual entrypoint whose
# deploy job cannot run unless the reusable Database Core job for the same event SHA succeeds.
grep -Fq 'workflow_dispatch:' "$deploy_workflow"
if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$deploy_workflow"; then
  echo 'Production deploy must never have an automatic trigger.' >&2
  exit 1
fi
grep -Fq 'expected_sha:' "$deploy_workflow"
grep -Fq "test \"\$EVENT_REF\" = 'refs/heads/main'" "$deploy_workflow"
grep -Fq 'test "$EXPECTED_SHA" = "$EVENT_SHA"' "$deploy_workflow"
grep -Fq 'uses: ./.github/workflows/db-core.yml' "$deploy_workflow"
grep -Fq 'needs: [validate-release, rebuild]' "$deploy_workflow"
grep -Fq 'environment: production' "$deploy_workflow"
grep -Fq 'ref: ${{ github.sha }}' "$deploy_workflow"
grep -Fq 'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"' "$deploy_workflow"
grep -Fq 'supabase db push --linked --dry-run' "$deploy_workflow"
grep -Fq 'supabase db push --linked --yes' "$deploy_workflow"
grep -Fq 'supabase functions deploy --project-ref "$SUPABASE_PROJECT_REF"' "$deploy_workflow"
if grep -Fq -- '--include-seed' "$deploy_workflow"; then
  echo 'Production deploy may not push seed data.' >&2
  exit 1
fi
if grep -Fq -- '--include-all' "$deploy_workflow"; then
  echo 'Production deploy may not use include-all against the legacy remote migration history.' >&2
  exit 1
fi
if grep -Fq 'db reset --linked' "$deploy_workflow"; then
  echo 'Production deploy may not reset the linked production database.' >&2
  exit 1
fi

grep -Fq 'workflow_call:' "$db_core_workflow"
grep -Fq 'Rebuild database from migrations' "$db_core_workflow"
grep -Fq 'Validate current ACL and RLS contract' "$db_core_workflow"
grep -Fq 'tests/acl-parity/item02c_acl_overlay.sql' "$db_core_workflow"
grep -Fq 'tests/rls-parity/production_rls_baseline.txt' "$db_core_workflow"
grep -Fq 'Run database test contract' "$db_core_workflow"
grep -Fq 'Run Gate A concurrency test' "$db_core_workflow"
grep -Fq 'Run action-token HTTP gate in disposable local stack' "$db_core_workflow"

# Negative proof 1: remove a migration required by the current ACL contract. A clean
# rebuild still starts, but the authoritative database test contract must reject it.
parked='/tmp/item02d-required-migration.sql'
restore_migration() {
  if [[ -f "$parked" ]]; then
    mv "$parked" "$migration"
  fi
}
trap restore_migration EXIT
mv "$migration" "$parked"
supabase db reset >/tmp/item02d-missing-reset.log 2>&1
set +e
bash scripts/test-database-core-gates.sh >/tmp/item02d-missing-migration.log 2>&1
missing_rc=$?
set -e
if [[ $missing_rc -eq 0 ]]; then
  echo 'Database contract unexpectedly passed with a required migration removed.' >&2
  cat /tmp/item02d-missing-migration.log >&2
  exit 1
fi
if ! grep -Eq 'not ok|ERROR|failed|FAILED' /tmp/item02d-missing-migration.log; then
  echo 'Missing-migration negative proof failed without a recognizable gate failure.' >&2
  cat /tmp/item02d-missing-migration.log >&2
  exit 1
fi
restore_migration
trap - EXIT

# Negative proof 2: introduce local ACL drift after a clean rebuild. The canonical ACL
# overlay used by Database Core must reject the drift before any production deployment.
supabase db reset >/tmp/item02d-clean-reset.log 2>&1
psql "$DB_URL" -v ON_ERROR_STOP=1 -c \
  'grant execute on function public.service_admin_upsert_change_policy(uuid,jsonb) to service_role;' \
  >/tmp/item02d-drift-inject.log 2>&1
set +e
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$overlay" >/tmp/item02d-drift-overlay.log 2>&1
drift_rc=$?
set -e
if [[ $drift_rc -eq 0 ]]; then
  echo 'ACL overlay unexpectedly accepted deliberate local drift.' >&2
  cat /tmp/item02d-drift-overlay.log >&2
  exit 1
fi
grep -Fq 'ITEM02C_PRIMITIVE_STILL_EXECUTABLE:' /tmp/item02d-drift-overlay.log

# Return the disposable stack to the versioned state and prove the current contracts.
supabase db reset >/tmp/item02d-final-reset.log 2>&1
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$overlay" | tee /tmp/item02d-final-acl.log
grep -Fxq 'ITEM02C_ACL_OVERLAY_OK' /tmp/item02d-final-acl.log
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f scripts/rls-inventory.sql \
  | sed '/^[[:space:]]*$/d' > /tmp/item02d-final-rls.txt
diff -u tests/rls-parity/production_rls_baseline.txt /tmp/item02d-final-rls.txt

echo 'ITEM02D_DEPLOY_GATE_OK'
