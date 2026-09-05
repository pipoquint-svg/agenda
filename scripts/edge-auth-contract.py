#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "supabase" / "functions" / "auth-contract.json"
CONFIG_PATH = ROOT / "supabase" / "config.toml"
DEPLOY_WORKFLOW_PATH = ROOT / ".github" / "workflows" / "production-deploy.yml"
FUNCTIONS_DIR = ROOT / "supabase" / "functions"

MODE_MARKERS: dict[str, list[list[str]]] = {
    "custom_admin": [["requireAdmin(", "requireAdminPermission("]],
    "gateway_admin": [["requireAdmin(", "requireAdminPermission("]],
    "public_rate_limited": [["enforceDistributedPublicRateLimit"]],
    "internal_secret": [["x-internal-secret"]],
    "mercado_pago_signature": [["verifyMercadoPagoWebhookSignature"], ["x-signature"]],
    "infinitepay_provider_check": [["parseInfinitePayWebhookSignal"], ["checkInfinitePayPayment"], ["verifyInfinitePayPayment"]],
    "google_channel_token": [["x-goog-channel-token"], ["channel_token_hash"]],
    "standard_webhooks": [["new Webhook"], ["SEND_EMAIL_HOOK_SECRET"]],
    "google_oauth_state": [["requireAdminPermission"], ["consume_google_oauth_state"]],
    "dual_admin_internal": [["x-internal-secret"], ["requireAdminPermission"]],
    "fastlane_secret": [["x-fastlane-secret"], ["service_verify_google_appointment_fastlane_secret"]],
    "github_oidc": [["jwtVerify"], ["assertGitHub"]],
    "retired_tombstone": [["410"]],
}

LEGACY_MISSING_FALSE = [
    "admin-finance-minimal",
    "admin-waitlist",
    "appointment-calendar",
    "balance-collection-access",
    "google-appointment-fastlane",
    "waitlist-signup",
]
LEGACY_INACTIVE_LOCAL = [
    "birthday-automation-trigger",
    "email-e2e-gate",
    "email-live-status",
    "email-provider-probe",
    "kommo-card-provider-gate",
    "kommo-guard-discovery",
    "kommo-guard-inspect",
    "kommo-provider-probe",
    "kommo-token-sender-once",
    "mercado-pago-card-staging",
    "payment-preview",
]

EXPECTED_BEFORE = sorted(
    [f"CONFIG_JWT_MISMATCH:{slug}:expected=false:actual=true" for slug in LEGACY_MISSING_FALSE]
    + ["CONFIG_JWT_MISMATCH:admin-special-calendar:expected=true:actual=false"]
    + ["DEPLOY_ALLOWLIST_COMMAND_MISSING", "DEPLOY_UNRESTRICTED"]
    + [f"DEPLOY_SURFACE_EXPANSION:{slug}" for slug in LEGACY_INACTIVE_LOCAL]
)


def load_manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def local_function_dirs() -> list[str]:
    return sorted(
        path.name
        for path in FUNCTIONS_DIR.iterdir()
        if path.is_dir() and path.name != "_shared" and not path.name.startswith(".")
    )


def source_text(slug: str) -> str:
    root = FUNCTIONS_DIR / slug
    runtime_files = sorted(
        path
        for path in root.rglob("*.ts")
        if path.is_file()
        and not path.name.endswith("_test.ts")
        and not path.name.endswith(".test.ts")
    )
    if not runtime_files:
        raise RuntimeError(f"FUNCTION_SOURCE_MISSING:{slug}")
    return "\n".join(path.read_text(encoding="utf-8") for path in runtime_files)


def parse_config(config_text: str) -> dict:
    return tomllib.loads(config_text)


def effective_verify_jwt(config: dict, slug: str) -> bool:
    raw = config.get("functions", {}).get(slug, {}).get("verify_jwt", True)
    if not isinstance(raw, bool):
        raise RuntimeError(f"CONFIG_VERIFY_JWT_INVALID:{slug}")
    return raw


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def validate_contract(config_text: str, deploy_text: str) -> list[str]:
    errors: list[str] = []
    manifest = load_manifest()
    deploy_groups = manifest.get("deployable", {})
    inactive_groups = manifest.get("inactive", {})
    orphans = manifest.get("production_orphans", {})
    true_modes = set(manifest.get("verify_jwt_true_modes", []))
    if not isinstance(deploy_groups, dict) or not isinstance(inactive_groups, dict) or not isinstance(orphans, dict):
        return ["MANIFEST_SHAPE_INVALID"]

    by_slug: dict[str, dict] = {}
    for deployable, groups in ((True, deploy_groups), (False, inactive_groups)):
        for auth_mode, slugs in groups.items():
            if not isinstance(slugs, list):
                errors.append(f"MANIFEST_GROUP_INVALID:{auth_mode}")
                continue
            for slug in slugs:
                slug = str(slug)
                if not slug or slug in by_slug:
                    errors.append(f"MANIFEST_SLUGS_INVALID:{slug}")
                    continue
                by_slug[slug] = {
                    "deployable": deployable,
                    "verify_jwt": auth_mode in true_modes,
                    "auth_mode": auth_mode,
                }

    local = local_function_dirs()
    manifest_slugs = sorted(by_slug)
    for slug in sorted(set(local) - set(manifest_slugs)):
        errors.append(f"MANIFEST_MISSING_LOCAL:{slug}")
    for slug in sorted(set(manifest_slugs) - set(local)):
        errors.append(f"MANIFEST_UNKNOWN_LOCAL:{slug}")

    orphan_slugs = set(orphans)
    for slug in sorted(orphan_slugs & set(local)):
        errors.append(f"ORPHAN_STILL_VERSIONED:{slug}")

    baseline = manifest.get("production_baseline", {})
    deployable = sorted(slug for slug, entry in by_slug.items() if entry.get("deployable") is True)
    inactive = sorted(slug for slug, entry in by_slug.items() if entry.get("deployable") is False)
    active_false = sum(
        1 for slug in deployable if by_slug[slug].get("verify_jwt") is False
    )
    active_true = sum(
        1 for slug in deployable if by_slug[slug].get("verify_jwt") is True
    )
    orphan_false = sum(1 for entry in orphans.values() if entry.get("verify_jwt") is False)
    orphan_true = sum(1 for entry in orphans.values() if entry.get("verify_jwt") is True)

    expected_counts = {
        "active_total": len(deployable) + len(orphans),
        "verify_jwt_false": active_false + orphan_false,
        "verify_jwt_true": active_true + orphan_true,
        "versioned_active": len(deployable),
        "production_orphans": len(orphans),
        "versioned_inactive": len(inactive),
    }
    for key, actual in expected_counts.items():
        if baseline.get(key) != actual:
            errors.append(f"MANIFEST_COUNT_MISMATCH:{key}:expected={baseline.get(key)}:actual={actual}")

    if sorted(inactive) != LEGACY_INACTIVE_LOCAL:
        errors.append("MANIFEST_INACTIVE_SET_DRIFT")

    config = parse_config(config_text)
    for slug, entry in sorted(by_slug.items()):
        expected = entry.get("verify_jwt")
        if not isinstance(expected, bool):
            errors.append(f"MANIFEST_VERIFY_JWT_INVALID:{slug}")
            continue
        actual = effective_verify_jwt(config, slug)
        if actual != expected:
            errors.append(
                f"CONFIG_JWT_MISMATCH:{slug}:expected={bool_text(expected)}:actual={bool_text(actual)}"
            )

        auth_mode = str(entry.get("auth_mode", ""))
        marker_groups = MODE_MARKERS.get(auth_mode)
        if marker_groups is None:
            errors.append(f"AUTH_MODE_UNKNOWN:{slug}:{auth_mode}")
            continue
        try:
            source = source_text(slug)
        except RuntimeError as exc:
            errors.append(str(exc))
            continue
        for group in marker_groups:
            if not any(marker in source for marker in group):
                errors.append(f"AUTH_BOUNDARY_MARKER_MISSING:{slug}:{auth_mode}:{'|'.join(group)}")

    deploy_command = "python3 scripts/edge-auth-contract.py list-deployable"
    if deploy_command not in deploy_text:
        errors.append("DEPLOY_ALLOWLIST_COMMAND_MISSING")

    unrestricted = re.search(
        r"supabase\s+functions\s+deploy\s+--project-ref\b",
        deploy_text,
    ) is not None
    if unrestricted:
        errors.append("DEPLOY_UNRESTRICTED")
        for slug in inactive:
            errors.append(f"DEPLOY_SURFACE_EXPANSION:{slug}")
    else:
        deploy_lines = [
            line.strip()
            for line in deploy_text.splitlines()
            if "supabase functions deploy" in line
        ]
        for line in deploy_lines:
            if '"$slug"' not in line and "${slug}" not in line:
                errors.append("DEPLOY_COMMAND_NOT_ALLOWLISTED")
                break

    return sorted(set(errors))


def remove_function_block(config_text: str, slug: str) -> str:
    pattern = re.compile(
        rf"(?m)^\[functions\.{re.escape(slug)}\]\nverify_jwt = (?:true|false)\n?"
    )
    return pattern.sub("", config_text)


def legacy_config(config_text: str) -> str:
    legacy = config_text
    for slug in LEGACY_MISSING_FALSE:
        legacy = remove_function_block(legacy, slug)
    legacy = re.sub(
        r"(?m)^\[functions\.admin-special-calendar\]\nverify_jwt = true",
        "[functions.admin-special-calendar]\nverify_jwt = false",
        legacy,
    )
    return legacy


def run_before() -> int:
    old_config = legacy_config(CONFIG_PATH.read_text(encoding="utf-8"))
    old_deploy = 'supabase functions deploy --project-ref "$SUPABASE_PROJECT_REF"\n'
    actual = validate_contract(old_config, old_deploy)
    if actual != EXPECTED_BEFORE:
        print("ITEM03_FAILING_BEFORE_MISMATCH", file=sys.stderr)
        print("expected:", file=sys.stderr)
        for item in EXPECTED_BEFORE:
            print(f"  {item}", file=sys.stderr)
        print("actual:", file=sys.stderr)
        for item in actual:
            print(f"  {item}", file=sys.stderr)
        return 1
    for item in actual:
        print(f"EXPECTED_BEFORE {item}")
    print("ITEM03_FAILING_BEFORE_OK")
    return 0


def run_after() -> int:
    errors = validate_contract(
        CONFIG_PATH.read_text(encoding="utf-8"),
        DEPLOY_WORKFLOW_PATH.read_text(encoding="utf-8"),
    )
    if errors:
        for item in errors:
            print(item, file=sys.stderr)
        return 1
    print("ITEM03_AUTH_CONTRACT_OK")
    return 0


def list_deployable() -> int:
    errors = validate_contract(
        CONFIG_PATH.read_text(encoding="utf-8"),
        DEPLOY_WORKFLOW_PATH.read_text(encoding="utf-8"),
    )
    if errors:
        for item in errors:
            print(item, file=sys.stderr)
        return 1
    manifest = load_manifest()
    slugs = sorted(
        str(slug)
        for group in manifest["deployable"].values()
        for slug in group
    )
    for slug in slugs:
        print(slug)
    return 0


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "after"
    if mode == "before":
        return run_before()
    if mode == "after":
        return run_after()
    if mode == "list-deployable":
        return list_deployable()
    print("usage: edge-auth-contract.py [before|after|list-deployable]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
