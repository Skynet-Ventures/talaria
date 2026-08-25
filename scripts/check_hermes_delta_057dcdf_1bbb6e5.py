#!/usr/bin/env python3
"""Fail-closed verification for the Hermes 057dcdf..1bbb6e5 delta audit."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "parity" / "hermes-delta-057dcdf-1bbb6e5.json"
BASE = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
TARGET = "1bbb6e5bce56e721ab685af4cd87df21bbff4d35"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
CLASSES = {"ios-portable", "desktop-only", "tests-metadata-merge"}
AUTHORITY_PATHS = (
    "apps/desktop/src/plugins/hermes-bots/plugin.js",
    "website/docs/user-guide/bot-mode.md",
    "website/docs/user-guide/desktop.md",
    "website/docs/user-guide/multi-connection-desktop.md",
    "apps/desktop/DESIGN.md",
)


class CheckError(RuntimeError):
    pass


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    try:
        return digest_bytes(path.read_bytes())
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error


def safe_path(value: object) -> Path:
    relative = Path(str(value))
    if relative.is_absolute() or ".." in relative.parts:
        raise CheckError(f"unsafe repository path: {relative}")
    return ROOT / relative


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CheckError("manifest must be an object")
    return value


def read_tsv(path: Path, header: list[str]) -> list[dict[str, str]]:
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if reader.fieldnames != header:
                raise CheckError(f"TSV header drift: {path}")
            rows = list(reader)
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise CheckError(f"malformed TSV row: {path}")
    return rows


def verify_manifest(manifest: dict[str, Any]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    expected = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "auditedAt",
        "talariaAuditBase", "range", "classifications", "authorityFiles",
        "portableDeltas", "portableNoClientChange", "pinDecision",
    }
    if set(manifest) != expected:
        raise CheckError(f"manifest key drift: {sorted(manifest)}")
    if manifest["schemaVersion"] != 1:
        raise CheckError("unsupported schemaVersion")
    if manifest["baseCommit"] != BASE or manifest["targetCommit"] != TARGET:
        raise CheckError("audit endpoint drift")
    if not SHA40.fullmatch(str(manifest["talariaAuditBase"])):
        raise CheckError("invalid Talaria audit base")

    range_info = manifest["range"]
    expected_range = {
        "commitCount", "changedPathCount", "additions", "deletions",
        "commitInventory", "commitInventorySha256", "pathInventory",
        "pathInventorySha256",
    }
    if set(range_info) != expected_range:
        raise CheckError("range schema drift")
    commit_path = safe_path(range_info["commitInventory"])
    path_path = safe_path(range_info["pathInventory"])
    for key, path in (
        ("commitInventorySha256", commit_path), ("pathInventorySha256", path_path)
    ):
        expected_digest = str(range_info[key])
        if not SHA64.fullmatch(expected_digest) or digest_file(path) != expected_digest:
            raise CheckError(f"inventory hash drift: {path.name}")

    commits = read_tsv(commit_path, ["commit", "parents", "classification", "subject"])
    paths = read_tsv(path_path, ["status", "path", "classification", "disposition"])
    if len(commits) != range_info["commitCount"] or len(commits) != 130:
        raise CheckError("commit inventory count drift")
    if len(paths) != range_info["changedPathCount"] or len(paths) != 324:
        raise CheckError("path inventory count drift")
    if len({row["commit"] for row in commits}) != len(commits):
        raise CheckError("duplicate commit inventory row")
    if len({row["path"] for row in paths}) != len(paths):
        raise CheckError("duplicate path inventory row")
    for row in commits:
        if not SHA40.fullmatch(row["commit"]):
            raise CheckError("invalid commit inventory SHA")
        if row["classification"] not in CLASSES or not row["subject"]:
            raise CheckError(f"invalid commit disposition: {row['commit']}")
    for row in paths:
        if row["status"] not in {"A", "M", "D"}:
            raise CheckError(f"invalid path status: {row['path']}")
        if row["classification"] not in CLASSES or not row["disposition"]:
            raise CheckError(f"invalid path disposition: {row['path']}")

    classes = manifest["classifications"]
    if set(classes) != {"commits", "paths"}:
        raise CheckError("classification schema drift")
    if Counter(row["classification"] for row in commits) != Counter(classes["commits"]):
        raise CheckError("commit classification count drift")
    if Counter(row["classification"] for row in paths) != Counter(classes["paths"]):
        raise CheckError("path classification count drift")

    authority = manifest["authorityFiles"]
    if tuple(row.get("path") for row in authority) != AUTHORITY_PATHS:
        raise CheckError("five-file authority inventory drift")
    if sum(row.get("changed") is True for row in authority) != 1:
        raise CheckError("authority changed-file count drift")
    for row in authority:
        if set(row) != {"path", "baseSha256", "targetSha256", "changed"}:
            raise CheckError(f"authority schema drift: {row.get('path')}")
        if not SHA64.fullmatch(str(row["baseSha256"])) or not SHA64.fullmatch(str(row["targetSha256"])):
            raise CheckError(f"invalid authority digest: {row['path']}")
        if row["changed"] != (row["baseSha256"] != row["targetSha256"]):
            raise CheckError(f"authority changed flag drift: {row['path']}")

    deltas = manifest["portableDeltas"]
    expected_ids = {
        "event-replay-wire", "pre-compress-checkpoint-v2",
        "terminal-environment-registry", "mcp-exclude-mode",
        "web-browser-cache-controls",
    }
    if {row.get("id") for row in deltas} != expected_ids:
        raise CheckError("portable delta inventory drift")
    if any(not str(row.get("status", "")).startswith("open-") or not row.get("requiredWork") for row in deltas):
        raise CheckError("portable delta must remain explicit and open")
    decision = manifest["pinDecision"]
    if set(decision) != {"canMoveCanonicalPin", "reason", "nextPin"}:
        raise CheckError("pin decision schema drift")
    if decision["canMoveCanonicalPin"] is not False or decision["nextPin"] != BASE:
        raise CheckError("canonical pin moved despite open portable deltas")
    return commits, paths


def git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout.rstrip("\n")


def verify_checkout(
    manifest: dict[str, Any], commits: list[dict[str, str]], paths: list[dict[str, str]], checkout: Path
) -> None:
    if git(checkout, "rev-parse", "HEAD") != TARGET:
        raise CheckError(f"Hermes checkout must be exact target {TARGET}")
    git(checkout, "merge-base", "--is-ancestor", BASE, TARGET)

    actual_commits = git(checkout, "rev-list", "--reverse", "--topo-order", f"{BASE}..{TARGET}").splitlines()
    if actual_commits != [row["commit"] for row in commits]:
        raise CheckError("exact commit inventory drift")
    for row in commits:
        actual = git(checkout, "show", "-s", "--format=%P%x09%s", row["commit"])
        if actual != f"{row['parents']}\t{row['subject']}":
            raise CheckError(f"commit metadata drift: {row['commit']}")

    raw_paths = git(checkout, "diff", "--name-status", BASE, TARGET).splitlines()
    actual_paths = []
    for raw in raw_paths:
        fields = raw.split("\t")
        actual_paths.append((fields[0], fields[-1]))
    if actual_paths != [(row["status"], row["path"]) for row in paths]:
        raise CheckError("exact changed-path inventory drift")

    additions = deletions = 0
    for raw in git(checkout, "diff", "--numstat", BASE, TARGET).splitlines():
        added, deleted, _path = raw.split("\t", 2)
        if added != "-":
            additions += int(added)
        if deleted != "-":
            deletions += int(deleted)
    if additions != manifest["range"]["additions"] or deletions != manifest["range"]["deletions"]:
        raise CheckError("range line-count drift")

    for row in manifest["authorityFiles"]:
        base_bytes = subprocess.run(
            ["git", "-C", str(checkout), "show", f"{BASE}:{row['path']}"],
            check=True, capture_output=True, timeout=60,
        ).stdout
        try:
            target_bytes = (checkout / row["path"]).read_bytes()
        except OSError as error:
            raise CheckError(f"authority target missing: {row['path']}") from error
        if digest_bytes(base_bytes) != row["baseSha256"]:
            raise CheckError(f"authority base hash drift: {row['path']}")
        if digest_bytes(target_bytes) != row["targetSha256"]:
            raise CheckError(f"authority target hash drift: {row['path']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--checkout", type=Path)
    arguments = parser.parse_args()
    try:
        manifest = load_manifest(arguments.manifest)
        commits, paths = verify_manifest(manifest)
        if arguments.checkout:
            verify_checkout(manifest, commits, paths, arguments.checkout.resolve())
    except CheckError as error:
        print(f"Hermes 057dcdf..1bbb6e5 audit failed: {error}", file=sys.stderr)
        return 1
    suffix = ", exact checkout" if arguments.checkout else ""
    print(f"Hermes 057dcdf..1bbb6e5 audit passed: 130 commits, 324 paths, canonical pin held{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
