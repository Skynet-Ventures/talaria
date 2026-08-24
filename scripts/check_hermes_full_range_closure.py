#!/usr/bin/env python3
"""Verify the complete 40643cba..057dcdf Hermes parity closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "parity" / "hermes-full-range-closure-40643cba-057dcdf.json"
BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_IDS = (
    "authority", "client-wire", "core-runtime", "desktop", "cli",
    "gateway-platform", "residual-runtime",
)


class CheckError(RuntimeError):
    pass


def digest(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CheckError("closure manifest must be an object")
    return value


def safe_repo_path(value: object) -> Path:
    path = Path(str(value))
    if path.is_absolute() or ".." in path.parts:
        raise CheckError(f"unsafe repository path: {path}")
    return ROOT / path


def verify_manifest(manifest: dict[str, Any]) -> None:
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit",
        "auditedAt", "talariaAuditBase", "methodology", "ledgers", "conclusion",
    }
    if set(manifest) != required:
        raise CheckError(f"closure keys drift: {sorted(manifest)}")
    if manifest["schemaVersion"] != 1:
        raise CheckError("unsupported closure schema")
    if manifest["baseCommit"] != BASE or manifest["targetCommit"] != TARGET:
        raise CheckError("closure endpoint drift")
    if not SHA40.fullmatch(str(manifest["talariaAuditBase"])):
        raise CheckError("invalid Talaria audit base")

    ledgers = manifest["ledgers"]
    if not isinstance(ledgers, list) or tuple(row.get("id") for row in ledgers) != EXPECTED_IDS:
        raise CheckError("closure must contain the seven ordered component ledgers")
    expected_keys = {
        "id", "metadataFile", "entriesFile", "checkerFile", "documentationFile",
        "metadataSha256", "entriesSha256", "scopedCommitCount",
    }
    for row in ledgers:
        if set(row) != expected_keys:
            raise CheckError(f"component schema drift: {row.get('id')}")
        if not isinstance(row["scopedCommitCount"], int) or row["scopedCommitCount"] <= 0:
            raise CheckError(f"invalid component count: {row['id']}")
        for key in ("metadataSha256", "entriesSha256"):
            if not SHA64.fullmatch(str(row[key])):
                raise CheckError(f"invalid {key}: {row['id']}")
        metadata_path = safe_repo_path(row["metadataFile"])
        entries_path = safe_repo_path(row["entriesFile"])
        checker_path = safe_repo_path(row["checkerFile"])
        documentation_path = safe_repo_path(row["documentationFile"])
        if not checker_path.is_file() or not documentation_path.is_file():
            raise CheckError(f"missing checker or documentation: {row['id']}")
        if digest(metadata_path) != row["metadataSha256"]:
            raise CheckError(f"component metadata hash drift: {row['id']}")
        if digest(entries_path) != row["entriesSha256"]:
            raise CheckError(f"component entries hash drift: {row['id']}")
        component = load_manifest(metadata_path)
        if component.get("baseCommit") != BASE or component.get("targetCommit") != TARGET:
            raise CheckError(f"component endpoint drift: {row['id']}")
        if component.get("scopedCommitCount", component.get("entryCount")) != row["scopedCommitCount"]:
            raise CheckError(f"component count drift: {row['id']}")

    conclusion = manifest["conclusion"]
    if set(conclusion) != {
        "undispositionedPortableGapCount", "openImplementationSlices",
        "upstreamContractBlockers",
    }:
        raise CheckError("closure conclusion schema drift")
    if conclusion["undispositionedPortableGapCount"] != 0:
        raise CheckError("closure contains an undispositioned portable gap")
    slices = conclusion["openImplementationSlices"]
    if [row.get("pullRequest") for row in slices] != [73, 91, 94, 95]:
        raise CheckError("open implementation slice inventory drift")
    for row in slices:
        if not SHA40.fullmatch(str(row.get("head", ""))):
            raise CheckError(f"invalid open-slice head: PR{row.get('pullRequest')}")
    if conclusion["upstreamContractBlockers"] != [
        "one-shot cron re-arm",
        "learned-memory row and import/export management",
        "auxiliary-model and MoA administration",
    ]:
        raise CheckError("upstream blocker inventory drift")


def run_component_checkers(manifest: dict[str, Any], checkout: Path | None) -> None:
    for row in manifest["ledgers"]:
        command = [sys.executable, str(safe_repo_path(row["checkerFile"]))]
        if checkout is not None:
            command.extend(["--checkout", str(checkout)])
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        if result.returncode:
            detail = (result.stderr or result.stdout).strip()
            raise CheckError(f"component checker failed: {row['id']}: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--checkout", type=Path)
    arguments = parser.parse_args()
    try:
        manifest = load_manifest(arguments.manifest)
        verify_manifest(manifest)
        run_component_checkers(
            manifest, arguments.checkout.resolve() if arguments.checkout else None)
    except CheckError as error:
        print(f"Hermes full-range closure failed: {error}", file=sys.stderr)
        return 1
    suffix = ", exact checkout" if arguments.checkout else ""
    print(f"Hermes full-range closure passed: seven ledgers, zero undispositioned gaps{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
