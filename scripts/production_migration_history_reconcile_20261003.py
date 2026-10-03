#!/usr/bin/env python3
"""Fail-closed reconciliation for the production migration history on 2026-10-03.

This changes only Supabase migration tracking metadata. It does not execute any
migration SQL. Production already contains the schema represented by the
canonical historical migrations below, but several deployments recorded
execution-time versions instead of repository versions.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path
from typing import Iterable, NoReturn

EXPECTED_PROJECT_REF = "sbexdggbwqvyhbkatucs"
MIGRATIONS_DIR = Path("supabase/migrations")
TARGET_PENDING = "20261003190846"

CANONICAL_ALREADY_DEPLOYED = frozenset(
    {
        "20260915194000",
        "20260915212000",
        "20260916133000",
        "20260916135500",
        "20260916143000",
        "20260916145000",
        "20260916150000",
        "20260923120000",
        "20260924125000",
        "20260924130500",
        "20260924132000",
    }
)

LEGACY_REMOTE_VERSIONS = frozenset(
    {
        "20260915205053",
        "20260915214649",
        "20260916130811",
        "20260916135514",
        "20260916142130",
        "20260916142608",
        "20260916143943",
        "20260924155014",
        "20260924155202",
        "20260924155644",
        "20260925152232",
        "20260925153151",
        "20260925153714",
        "20260930150139",
        "20260930150237",
    }
)

VERSION_RE = re.compile(r"^(\d{14})_.+\.sql$")
REMOTE_VERSION_RE = re.compile(r"^\d{14}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


class ReconcileError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ReconcileError(message)


def read_local_versions() -> set[str]:
    by_version: dict[str, list[str]] = {}
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        match = VERSION_RE.fullmatch(path.name)
        if match:
            by_version.setdefault(match.group(1), []).append(path.name)
    duplicates = {version: names for version, names in by_version.items() if len(names) > 1}
    if duplicates:
        fail(f"duplicate local migration versions: {duplicates}")
    versions = set(by_version)
    required = set(CANONICAL_ALREADY_DEPLOYED) | {TARGET_PENDING}
    missing = sorted(required - versions)
    if missing:
        fail(f"required canonical migrations are missing: {missing}")
    if set(LEGACY_REMOTE_VERSIONS) & versions:
        fail("legacy remote-only versions unexpectedly exist in the repository")
    return versions


def parse_remote_versions(text: str) -> set[str]:
    versions: set[str] = set()
    clean = ANSI_RE.sub("", text).replace("│", "|")
    for line in clean.splitlines():
        parts = line.split("|")
        if len(parts) < 2:
            continue
        remote = parts[1].strip().strip("`").strip()
        if REMOTE_VERSION_RE.fullmatch(remote):
            versions.add(remote)
    if not versions:
        fail("could not parse remote migration versions")
    return versions


def run_cli(args: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    command = ["supabase", *args]
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, check=True, text=True, capture_output=capture)


def read_remote_versions() -> set[str]:
    result = run_cli(["migration", "list", "--linked"], capture=True)
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    print(output, end="" if output.endswith("\n") else "\n")
    return parse_remote_versions(output)


def assert_linked_project(project_ref: str) -> None:
    if project_ref != EXPECTED_PROJECT_REF:
        fail(f"unexpected project ref: {project_ref}")
    marker = Path("supabase/.temp/project-ref")
    if not marker.is_file() or marker.read_text(encoding="utf-8").strip() != EXPECTED_PROJECT_REF:
        fail("Supabase CLI is not linked to the expected production project")


def classify(local: set[str], remote: set[str]) -> tuple[set[str], set[str]]:
    if TARGET_PENDING in remote:
        fail(f"target migration {TARGET_PENDING} is already applied; refusing one-time repair")

    stable = local - set(CANONICAL_ALREADY_DEPLOYED) - {TARGET_PENDING}
    missing_stable = sorted(stable - remote)
    if missing_stable:
        fail(f"previously aligned canonical migrations are missing remotely: {missing_stable}")

    unexpected_remote = sorted(remote - local - set(LEGACY_REMOTE_VERSIONS))
    if unexpected_remote:
        fail(f"unexpected remote-only versions: {unexpected_remote}")

    missing_canonical = set(CANONICAL_ALREADY_DEPLOYED) - remote
    if not missing_canonical <= set(CANONICAL_ALREADY_DEPLOYED):
        fail("unexpected canonical migration state")

    remaining_legacy = remote & set(LEGACY_REMOTE_VERSIONS)
    print(
        "reconciliation-state: "
        f"canonical_metadata_missing={sorted(missing_canonical)} "
        f"legacy_metadata_present={sorted(remaining_legacy)} "
        f"pending_target={TARGET_PENDING}"
    )
    return missing_canonical, remaining_legacy


def repair(versions: Iterable[str], status: str) -> None:
    ordered = sorted(set(versions))
    if ordered:
        run_cli(["migration", "repair", *ordered, "--status", status, "--linked"])


def audit_state(local: set[str], remote: set[str]) -> tuple[set[str], set[str]]:
    missing_canonical, remaining_legacy = classify(local, remote)
    expected_remote = local - {TARGET_PENDING} - missing_canonical
    expected_remote |= remaining_legacy
    if remote != expected_remote:
        fail(
            "remote history is outside the exact allowed reconciliation state: "
            f"missing={sorted(expected_remote - remote)} extra={sorted(remote - expected_remote)}"
        )
    return missing_canonical, remaining_legacy


def command_audit_local() -> None:
    local = read_local_versions()
    canonical = set(CANONICAL_ALREADY_DEPLOYED)
    legacy = set(LEGACY_REMOTE_VERSIONS)
    stable = local - canonical - {TARGET_PENDING}
    initial = stable | legacy
    midway = stable | canonical | legacy
    final = local - {TARGET_PENDING}
    if audit_state(local, initial) != (canonical, legacy):
        fail("initial state-machine audit failed")
    if audit_state(local, midway) != (set(), legacy):
        fail("midway state-machine audit failed")
    if audit_state(local, final) != (set(), set()):
        fail("final state-machine audit failed")
    print("LOCAL AUDIT PASS")


def command_apply(project_ref: str) -> None:
    assert_linked_project(project_ref)
    local = read_local_versions()
    missing_canonical, _ = audit_state(local, read_remote_versions())
    repair(missing_canonical, "applied")

    _, remaining_legacy = audit_state(local, read_remote_versions())
    repair(remaining_legacy, "reverted")
    command_verify_ready(project_ref)


def command_verify_ready(project_ref: str) -> None:
    assert_linked_project(project_ref)
    local = read_local_versions()
    remote = read_remote_versions()
    audit_state(local, remote)
    expected = local - {TARGET_PENDING}
    if remote != expected:
        fail(
            "history is not ready for deployment: "
            f"local_only={sorted(local - remote)} remote_only={sorted(remote - local)}"
        )
    print(f"READY: only migration {TARGET_PENDING} is pending")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("audit-local")
    for name in ("apply", "verify-ready"):
        child = subparsers.add_parser(name)
        child.add_argument("--project-ref", required=True)
    args = parser.parse_args()

    try:
        if args.command == "audit-local":
            command_audit_local()
        elif args.command == "apply":
            command_apply(args.project_ref)
        else:
            command_verify_ready(args.project_ref)
    except (ReconcileError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
