#!/usr/bin/env python3
"""Fail-closed one-time reconciliation of legacy production migration history.

This tool changes Supabase migration *tracking metadata only* via
`supabase migration repair`. It never executes schema SQL itself.

The production database predates the canonical repository migration history:
- many migrations were recorded with execution-time versions;
- release-candidate bundles/micros grouped multiple canonical files;
- a few operational records exist only in the remote history.

For the Item 4 rollout we treat the current production schema as the historical
baseline through BASELINE_CUTOFF. Historical repository migrations are marked as
already absorbed; they must never be replayed against production. The canonical
post-baseline chain must start with Item 4 and may continue with later migrations.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, NoReturn

EXPECTED_PROJECT_REF = "sbexdggbwqvyhbkatucs"
BASELINE_CUTOFF = "20260902214000"
TARGET_VERSION = "20260902233000"
EXPECTED_INITIAL_COUNT = 178
EXPECTED_INITIAL_MIN = "20260821160000"
EXPECTED_INITIAL_MAX = "20260902224016"
EXPECTED_INITIAL_MD5 = "9073b0c44a6662a3af71d63388b36173"
MANIFEST_PATH = Path("docs/audit/production-migration-history-2026-09-03.tsv")
MIGRATIONS_DIR = Path("supabase/migrations")
VERSION_RE = re.compile(r"^(\d{14})_.+\.sql$")
REMOTE_VERSION_RE = re.compile(r"^\d{14}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


class BaselineError(RuntimeError):
    pass


@dataclass(frozen=True)
class Plan:
    initial: frozenset[str]
    final: frozenset[str]
    to_apply: frozenset[str]
    to_revert: frozenset[str]
    intermediate: frozenset[str]


def _fail(message: str) -> NoReturn:
    raise BaselineError(message)


def _md5_versions(versions: Iterable[str]) -> str:
    payload = "\n".join(sorted(versions)) + "\n"
    return hashlib.md5(payload.encode("utf-8")).hexdigest()


def read_manifest_versions(path: Path = MANIFEST_PATH) -> set[str]:
    if not path.is_file():
        _fail(f"audit manifest missing: {path}")
    versions: list[str] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 4:
            _fail(f"manifest line {lineno} must have 4 tab-separated fields")
        version, _name, statement_md5, sql_chars = parts
        if not REMOTE_VERSION_RE.fullmatch(version):
            _fail(f"invalid manifest version on line {lineno}: {version}")
        if not re.fullmatch(r"[0-9a-f]{32}", statement_md5):
            _fail(f"invalid statement md5 on line {lineno}: {statement_md5}")
        if not sql_chars.isdigit():
            _fail(f"invalid sql length on line {lineno}: {sql_chars}")
        versions.append(version)
    if len(versions) != len(set(versions)):
        _fail("audit manifest contains duplicate versions")
    version_set = set(versions)
    if len(version_set) != EXPECTED_INITIAL_COUNT:
        _fail(f"manifest count drift: {len(version_set)} != {EXPECTED_INITIAL_COUNT}")
    if min(version_set) != EXPECTED_INITIAL_MIN or max(version_set) != EXPECTED_INITIAL_MAX:
        _fail("manifest min/max drift")
    if _md5_versions(version_set) != EXPECTED_INITIAL_MD5:
        _fail("manifest version fingerprint drift")
    return version_set


def read_local_versions(root: Path = MIGRATIONS_DIR) -> set[str]:
    if not root.is_dir():
        _fail(f"migrations directory missing: {root}")
    by_version: dict[str, list[str]] = {}
    for path in sorted(root.glob("*.sql")):
        match = VERSION_RE.fullmatch(path.name)
        if not match:
            continue
        by_version.setdefault(match.group(1), []).append(path.name)
    duplicates = {v: names for v, names in by_version.items() if len(names) > 1}
    if duplicates:
        _fail(f"duplicate local migration versions: {duplicates}")
    versions = set(by_version)
    if BASELINE_CUTOFF not in versions:
        _fail(f"baseline cutoff migration missing: {BASELINE_CUTOFF}")
    if TARGET_VERSION not in versions:
        _fail(f"Item 4 target migration missing: {TARGET_VERSION}")
    post_baseline = sorted(v for v in versions if v > BASELINE_CUTOFF)
    if not post_baseline or post_baseline[0] != TARGET_VERSION:
        _fail(
            "post-baseline migration chain must start with Item 4 target; "
            f"got: {post_baseline}"
        )
    return versions


def build_plan(local_versions: set[str], initial_versions: set[str]) -> Plan:
    baseline = frozenset(v for v in local_versions if v <= BASELINE_CUTOFF)
    if not baseline:
        _fail("empty local baseline")
    if TARGET_VERSION in baseline:
        _fail("target version unexpectedly inside historical baseline")
    initial = frozenset(initial_versions)
    to_apply = baseline - initial
    to_revert = initial - baseline
    intermediate = initial | to_apply
    return Plan(
        initial=initial,
        final=baseline,
        to_apply=frozenset(to_apply),
        to_revert=frozenset(to_revert),
        intermediate=frozenset(intermediate),
    )


def parse_remote_versions(text: str) -> set[str]:
    versions: set[str] = set()
    clean = ANSI_RE.sub("", text).replace("│", "|")
    for line in clean.splitlines():
        parts = line.split("|")
        if len(parts) < 2:
            continue
        # Supabase CLI 2.111.0 renders migration-list cells wrapped in
        # Markdown-style backticks even in plain captured output. Normalize
        # only those outer delimiters; the strict 14-digit validation below
        # still rejects headers, blanks, timestamps, and arbitrary text.
        remote = parts[1].strip().strip("`").strip()
        if REMOTE_VERSION_RE.fullmatch(remote):
            versions.add(remote)
    if not versions:
        _fail("could not parse any remote migration versions from Supabase CLI output")
    return versions


def run_cli(args: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    cmd = ["supabase", *args]
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(
        cmd,
        check=True,
        text=True,
        capture_output=capture,
    )


def read_remote_versions() -> set[str]:
    result = run_cli(["migration", "list", "--linked"], capture=True)
    combined = (result.stdout or "") + "\n" + (result.stderr or "")
    print(combined, end="" if combined.endswith("\n") else "\n")
    return parse_remote_versions(combined)


def assert_linked_project(expected_ref: str) -> None:
    if expected_ref != EXPECTED_PROJECT_REF:
        _fail(f"unexpected project ref argument: {expected_ref}")
    ref_file = Path("supabase/.temp/project-ref")
    if not ref_file.is_file():
        _fail("Supabase linked project marker missing; run `supabase link` first")
    linked = ref_file.read_text(encoding="utf-8").strip()
    if linked != EXPECTED_PROJECT_REF:
        _fail(f"wrong linked project: {linked}")


def describe(plan: Plan) -> None:
    print(
        "migration-history-plan: "
        f"initial={len(plan.initial)} "
        f"baseline={len(plan.final)} "
        f"apply_metadata={len(plan.to_apply)} "
        f"revert_metadata={len(plan.to_revert)} "
        f"target={TARGET_VERSION}"
    )


def classify_state(current: set[str], plan: Plan) -> str:
    frozen = frozenset(current)
    if TARGET_VERSION in frozen:
        _fail(
            f"target {TARGET_VERSION} is already recorded remotely; one-time baseline must not run"
        )
    if frozen == plan.final:
        return "final"
    # Once every canonical baseline version is present, we are in the removal
    # phase even when every legacy row is still present (the full intermediate
    # set). Check this before the broader apply-phase subset relation.
    if plan.final <= frozen <= plan.intermediate:
        return "revert"
    # Apply phase may be interrupted after any subset of canonical additions.
    if plan.initial <= frozen <= plan.intermediate:
        return "apply"
    unexpected_added = sorted(frozen - plan.intermediate)
    unexpectedly_missing = sorted((plan.initial & plan.final) - frozen)
    _fail(
        "remote migration history is outside every allowed state; refusing repair. "
        f"unexpected_added={unexpected_added} unexpectedly_missing_common={unexpectedly_missing} "
        f"count={len(frozen)} md5={_md5_versions(frozen)}"
    )


def repair_versions(versions: Iterable[str], status: str) -> None:
    ordered = sorted(set(versions))
    if not ordered:
        return
    if status not in {"applied", "reverted"}:
        _fail(f"invalid repair status: {status}")
    run_cli(["migration", "repair", *ordered, "--status", status, "--linked"])


def verify_ready(local_versions: set[str], remote_versions: set[str], plan: Plan) -> None:
    if frozenset(remote_versions) != plan.final:
        _fail(
            "remote history is not the canonical historical baseline: "
            f"count={len(remote_versions)} md5={_md5_versions(remote_versions)}"
        )
    local_only = sorted(local_versions - remote_versions)
    remote_only = sorted(remote_versions - local_versions)
    if remote_only:
        _fail(f"remote-only versions remain after baseline: {remote_only}")
    expected_pending = sorted(v for v in local_versions if v > BASELINE_CUTOFF)
    if local_only != expected_pending:
        _fail(
            "post-baseline migration chain is not the exact pending local chain: "
            f"expected={expected_pending} actual={local_only}"
        )
    if not local_only or local_only[0] != TARGET_VERSION:
        _fail(f"pending migration chain must start with Item 4 target {TARGET_VERSION}")
    print(
        "READY: canonical post-baseline migration chain is pending; "
        f"count={len(local_only)} first={TARGET_VERSION}"
    )


def command_audit_local() -> None:
    manifest = read_manifest_versions()
    local = read_local_versions()
    plan = build_plan(local, manifest)
    describe(plan)
    # Prove the state machine accepts only the intended progression.
    initial_state = classify_state(set(plan.initial), plan)
    if plan.to_apply and initial_state != "apply":
        _fail("initial state classification failed")
    if not plan.to_apply and initial_state not in {"revert", "final"}:
        _fail("initial state classification failed without additions")
    if classify_state(set(plan.intermediate), plan) not in {"revert", "final"}:
        _fail("intermediate state classification failed")
    if classify_state(set(plan.final), plan) != "final":
        _fail("final state classification failed")
    post_baseline = sorted(v for v in local if v > BASELINE_CUTOFF)
    if not post_baseline or post_baseline[0] != TARGET_VERSION:
        _fail("canonical post-baseline chain does not start with Item 4 target")
    print(f"LOCAL AUDIT PASS: post-baseline migrations={len(post_baseline)}")


def command_apply(project_ref: str) -> None:
    assert_linked_project(project_ref)
    manifest = read_manifest_versions()
    local = read_local_versions()
    plan = build_plan(local, manifest)
    describe(plan)

    current = read_remote_versions()
    state = classify_state(current, plan)

    if state == "apply":
        missing = plan.final - current
        print(f"phase=apply metadata additions={len(missing)}")
        repair_versions(missing, "applied")
        current = read_remote_versions()
        state = classify_state(current, plan)

    if state == "revert":
        extras = current - plan.final
        print(f"phase=revert legacy metadata extras={len(extras)}")
        repair_versions(extras, "reverted")
        current = read_remote_versions()
        state = classify_state(current, plan)

    if state != "final":
        _fail(f"reconciliation did not reach final state: {state}")
    verify_ready(local, current, plan)


def command_verify_ready(project_ref: str) -> None:
    assert_linked_project(project_ref)
    manifest = read_manifest_versions()
    local = read_local_versions()
    plan = build_plan(local, manifest)
    describe(plan)
    current = read_remote_versions()
    verify_ready(local, current, plan)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("audit-local")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--project-ref", required=True)
    verify_parser = sub.add_parser("verify-ready")
    verify_parser.add_argument("--project-ref", required=True)
    args = parser.parse_args()

    try:
        if args.command == "audit-local":
            command_audit_local()
        elif args.command == "apply":
            command_apply(args.project_ref)
        elif args.command == "verify-ready":
            command_verify_ready(args.project_ref)
        else:  # pragma: no cover
            _fail(f"unsupported command: {args.command}")
    except BaselineError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"ERROR: Supabase CLI failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
