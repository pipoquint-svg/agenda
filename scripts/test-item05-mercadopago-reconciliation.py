#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECONCILER = ROOT / "supabase/functions/mercado-pago-reconcile/index.ts"
LOGIC = ROOT / "supabase/functions/mercado-pago-reconcile/logic.ts"
LOGIC_TEST = ROOT / "supabase/functions/mercado-pago-reconcile/logic_test.ts"
TRIGGER = ROOT / "supabase/functions/integration-worker-trigger/index.ts"
MANIFEST = ROOT / "supabase/functions/auth-contract.json"
CONFIG = ROOT / "supabase/config.toml"
WORKFLOW = ROOT / ".github/workflows/item05-mercadopago-reconciliation.yml"


def require(condition: bool, code: str, errors: list[str]) -> None:
    if not condition:
        errors.append(code)


def main() -> int:
    errors: list[str] = []
    require(RECONCILER.exists(), "RECONCILER_MISSING", errors)
    require(LOGIC.exists(), "RECONCILIATION_LOGIC_MISSING", errors)
    require(LOGIC_TEST.exists(), "RECONCILIATION_BEHAVIOR_TEST_MISSING", errors)

    source = ""
    if RECONCILER.exists():
        source += RECONCILER.read_text(encoding="utf-8")
    if LOGIC.exists():
        source += "\n" + LOGIC.read_text(encoding="utf-8")

    if source:
        require("x-internal-secret" in source, "INTERNAL_AUTH_MISSING", errors)
        require("MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN" in source or "mercadoPagoRuntime" in source, "PROVIDER_RUNTIME_MISSING", errors)
        require("https://api.mercadopago.com/v1/orders/${" in source, "ORDER_LOOKUP_MISSING", errors)
        require("method: 'GET'" in source, "ORDER_LOOKUP_NOT_GET", errors)
        require("creatingCharge: true" not in source, "RECONCILER_CAN_CREATE_CHARGE", errors)
        require(".eq('provider', 'MERCADO_PAGO')" in source, "PROVIDER_FILTER_MISSING", errors)
        require(".eq('transaction_type', 'CHARGE')" in source, "CHARGE_FILTER_MISSING", errors)
        require(".eq('status', 'PENDING')" in source, "PENDING_FILTER_MISSING", errors)
        require(".not('provider_payment_id', 'is', null)" in source, "PROVIDER_ID_FILTER_MISSING", errors)
        require("RECONCILE_MIN_AGE_MS" in source, "STALE_AGE_GUARD_MISSING", errors)
        require("RECONCILE_DISCOVERY_LIMIT" in source and ".limit(RECONCILE_DISCOVERY_LIMIT)" in source, "DISCOVERY_BOUND_MISSING", errors)
        require(".slice(0, RECONCILE_LIMIT)" in source, "ENQUEUE_BATCH_BOUND_MISSING", errors)
        require("RECONCILE_CONCURRENCY" in source, "CONCURRENCY_BOUND_MISSING", errors)
        require("assertMercadoPagoPaymentMatchesIntent" in source, "INTENT_VALIDATION_MISSING", errors)
        require("service_quarantine_provider_payment_mismatch" in source, "MISMATCH_QUARANTINE_MISSING", errors)
        require("PROVIDER_INTENT_MISMATCH" in source and ".eq('status', 'OPEN')" in source, "OPEN_MISMATCH_SKIP_MISSING", errors)
        require("apply_provider_payment_status" in source, "STATE_MACHINE_REUSE_MISSING", errors)
        require("transaction_status" in source, "STATE_MACHINE_RESULT_NOT_READ", errors)
        require("reconcile:${snapshot.id}" in source, "DETERMINISTIC_EVENT_KEY_MISSING", errors)
        require("RECONCILE_JOB_TYPE = 'MERCADO_PAGO_RECONCILE'" in source, "INTEGRATION_JOB_TYPE_MISSING", errors)
        require(".from('integration_jobs')" in source, "INTEGRATION_JOB_QUEUE_MISSING", errors)
        require("idempotency_key: `mercado-pago-reconcile:${candidate.id}:${bucket}`" in source, "JOB_IDEMPOTENCY_KEY_MISSING", errors)
        require("ignoreDuplicates: true" in source, "JOB_ENQUEUE_IDEMPOTENCY_MISSING", errors)
        require(".in('status', ['PENDING', 'PROCESSING'])" in source, "ACTIVE_JOB_DEDUP_MISSING", errors)
        require("claim_integration_jobs" in source, "JOB_CLAIM_MISSING", errors)
        require("finish_integration_job" in source, "JOB_FINISH_MISSING", errors)
        require("max_attempts: 5" in source, "MAX_ATTEMPTS_MISSING", errors)
        require("reconcileRetryDelaySeconds" in source, "RETRY_BACKOFF_MISSING", errors)
        require("[30, 120, 600, 1800]" in source, "RETRY_SCHEDULE_MISSING", errors)
        require("MERCADO_PAGO_PAYMENT_VALIDATION_FAILED" in source and "nonRetryable" in source, "MISMATCH_NON_RETRYABLE_MISSING", errors)
        require(", 502" in source, "FAILURE_NOT_OBSERVABLE", errors)

    trigger = TRIGGER.read_text(encoding="utf-8")
    require("'mercado-pago-reconcile'" in trigger, "SCHEDULER_WIRING_MISSING", errors)
    require("mercado_pago_reconcile" in trigger, "SCHEDULER_RESULT_MISSING", errors)

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    internal = manifest.get("deployable", {}).get("internal_secret", [])
    require("mercado-pago-reconcile" in internal, "DEPLOY_ALLOWLIST_MISSING", errors)
    require(manifest.get("production_baseline", {}).get("active_total") == 64, "ACTIVE_TOTAL_NOT_UPDATED", errors)
    require(manifest.get("production_baseline", {}).get("verify_jwt_false") == 49, "JWT_FALSE_COUNT_NOT_UPDATED", errors)
    require(manifest.get("production_baseline", {}).get("versioned_active") == 59, "VERSIONED_ACTIVE_COUNT_NOT_UPDATED", errors)

    config = CONFIG.read_text(encoding="utf-8")
    require("[functions.mercado-pago-reconcile]\nverify_jwt = false" in config, "CONFIG_AUTH_MISSING", errors)

    workflow = WORKFLOW.read_text(encoding="utf-8")
    require("denoland/setup-deno" in workflow, "DENO_SETUP_MISSING", errors)
    require("deno test supabase/functions/mercado-pago-reconcile/logic_test.ts" in workflow, "BEHAVIOR_TEST_NOT_WIRED", errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("ITEM05_MERCADO_PAGO_RECONCILIATION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
