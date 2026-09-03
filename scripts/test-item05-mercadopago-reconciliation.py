#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECONCILER = ROOT / "supabase/functions/mercado-pago-reconcile/index.ts"
TRIGGER = ROOT / "supabase/functions/integration-worker-trigger/index.ts"
MANIFEST = ROOT / "supabase/functions/auth-contract.json"
CONFIG = ROOT / "supabase/config.toml"


def require(condition: bool, code: str, errors: list[str]) -> None:
    if not condition:
        errors.append(code)


def main() -> int:
    errors: list[str] = []
    require(RECONCILER.exists(), "RECONCILER_MISSING", errors)
    if RECONCILER.exists():
        source = RECONCILER.read_text(encoding="utf-8")
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
        require("RECONCILE_LIMIT" in source and ".limit(RECONCILE_LIMIT)" in source, "BOUNDED_BATCH_MISSING", errors)
        require("assertMercadoPagoPaymentMatchesIntent" in source, "INTENT_VALIDATION_MISSING", errors)
        require("service_quarantine_provider_payment_mismatch" in source, "MISMATCH_QUARANTINE_MISSING", errors)
        require("apply_provider_payment_status" in source, "STATE_MACHINE_REUSE_MISSING", errors)
        require("status: 502" in source or ", 502" in source, "FAILURE_NOT_OBSERVABLE", errors)

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

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("ITEM05_MERCADO_PAGO_RECONCILIATION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
