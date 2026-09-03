#!/usr/bin/env bash
set -euo pipefail

python3 scripts/production_migration_history_baseline.py audit-local

python3 - <<'PY'
import importlib.util
import sys
from pathlib import Path

path = Path('scripts/production_migration_history_baseline.py')
spec = importlib.util.spec_from_file_location('migration_baseline', path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Parser accepts the Unicode table emitted by Supabase CLI and ignores headers.
sample = '''
        LOCAL      │     REMOTE     │     TIME (UTC)
  ─────────────────┼────────────────┼──────────────────────
                   │ 20260827094437 │ 2026-08-27 09:44:37
   20260902233000  │                │ 2026-09-02 23:30:00
'''
assert module.parse_remote_versions(sample) == {'20260827094437'}

# State-machine resume contract: additions may be partially completed, then
# legacy removals may be partially completed, but foreign states fail closed.
initial = {'20260101000000', '20260101000010'}
local = {'20260101000000', '20260101000020', module.TARGET_VERSION}
old_cutoff = module.BASELINE_CUTOFF
module.BASELINE_CUTOFF = '20260101000020'
try:
    plan = module.build_plan(local, initial)
    assert module.classify_state(initial, plan) == 'apply'
    fully_applied = initial | {'20260101000020'}
    assert module.classify_state(fully_applied, plan) == 'revert'
    partially_reverted = {'20260101000000', '20260101000020'}
    assert module.classify_state(partially_reverted, plan) == 'final'
    try:
        module.classify_state({'20990101000000'}, plan)
    except module.BaselineError:
        pass
    else:
        raise AssertionError('unexpected remote state must fail closed')
finally:
    module.BASELINE_CUTOFF = old_cutoff

workflow = Path('.github/workflows/production-deploy.yml').read_text(encoding='utf-8')
required = [
    'reconcile_migration_history:',
    'python3 scripts/production_migration_history_baseline.py apply',
    'python3 scripts/production_migration_history_baseline.py verify-ready',
    'supabase db push --linked --dry-run',
    'supabase db push --linked --yes',
]
for token in required:
    assert token in workflow, f'missing production deploy contract token: {token}'
positions = [workflow.index(token) for token in required[1:]]
assert positions == sorted(positions), 'reconcile/verify/dry-run/push order regressed'
assert '--include-all' not in workflow, 'production deploy must never use --include-all'

print('MIGRATION HISTORY BASELINE TEST PASS')
PY
