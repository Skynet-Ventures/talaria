#!/usr/bin/env python3
"""Fail-closed verification for the exact Hermes 1bbb6e5..02c7ae9 audit."""

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
DEFAULT_MANIFEST = ROOT / "parity" / "hermes-delta-1bbb6e5-02c7ae9.json"
BASE = "1bbb6e5bce56e721ab685af4cd87df21bbff4d35"
TARGET = "02c7ae956e42891d5e337a921b45de0a6067146d"
PIN = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
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


def digest(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error


def repository_path(value: object) -> Path:
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
        "range", "classifications", "authorityFiles", "portableDeltas",
        "portableNoClientChange", "pinDecision",
    }
    if set(manifest) != expected or manifest.get("schemaVersion") != 1:
        raise CheckError("manifest schema drift")
    if manifest.get("baseCommit") != BASE or manifest.get("targetCommit") != TARGET:
        raise CheckError("audit endpoint drift")

    range_info = manifest.get("range")
    if not isinstance(range_info, dict) or set(range_info) != {
        "commitCount", "changedPathCount", "additions", "deletions",
        "commitInventory", "commitInventorySha256", "pathInventory",
        "pathInventorySha256",
    }:
        raise CheckError("range schema drift")
    commit_path = repository_path(range_info["commitInventory"])
    path_path = repository_path(range_info["pathInventory"])
    for hash_key, path in (("commitInventorySha256", commit_path),
                           ("pathInventorySha256", path_path)):
        expected_hash = str(range_info[hash_key])
        if not SHA64.fullmatch(expected_hash) or digest(path) != expected_hash:
            raise CheckError(f"inventory hash drift: {path.name}")

    commits = read_tsv(commit_path, ["commit", "parents", "classification", "subject"])
    paths = read_tsv(path_path, ["status", "path", "classification", "disposition"])
    if len(commits) != 3 or len(commits) != range_info["commitCount"]:
        raise CheckError("commit inventory count drift")
    if len(paths) != 6 or len(paths) != range_info["changedPathCount"]:
        raise CheckError("path inventory count drift")
    if len({row["commit"] for row in commits}) != len(commits):
        raise CheckError("duplicate commit row")
    if len({row["path"] for row in paths}) != len(paths):
        raise CheckError("duplicate path row")
    if any(not SHA40.fullmatch(row["commit"]) or row["classification"] not in CLASSES
           or not row["parents"] or not row["subject"] for row in commits):
        raise CheckError("invalid commit inventory row")
    if any(row["status"] not in {"A", "M", "D"}
           or row["classification"] not in CLASSES or not row["disposition"] for row in paths):
        raise CheckError("invalid path inventory row")

    classes = manifest.get("classifications")
    if not isinstance(classes, dict) or set(classes) != {"commits", "paths"}:
        raise CheckError("classification schema drift")
    if Counter(row["classification"] for row in commits) != Counter(classes["commits"]):
        raise CheckError("commit classification drift")
    if Counter(row["classification"] for row in paths) != Counter(classes["paths"]):
        raise CheckError("path classification drift")

    authority = manifest.get("authorityFiles")
    if not isinstance(authority, list) or tuple(row.get("path") for row in authority) != AUTHORITY_PATHS:
        raise CheckError("authority inventory drift")
    for row in authority:
        if set(row) != {"path", "baseSha256", "targetSha256", "changed"}:
            raise CheckError("authority schema drift")
        if row["changed"] is not False or row["baseSha256"] != row["targetSha256"]:
            raise CheckError("authority file unexpectedly changed")
        if not SHA64.fullmatch(str(row["baseSha256"])):
            raise CheckError("invalid authority digest")

    if manifest.get("portableDeltas") != []:
        raise CheckError("successor audit introduced unclassified client work")
    no_change = manifest.get("portableNoClientChange")
    if not isinstance(no_change, list) or len(no_change) != 2 or any(not item for item in no_change):
        raise CheckError("portable no-client-change evidence drift")
    decision = manifest.get("pinDecision")
    if not isinstance(decision, dict) or set(decision) != {
        "canMoveCanonicalPin", "reason", "nextPin"
    }:
        raise CheckError("pin decision schema drift")
    if decision["canMoveCanonicalPin"] is not False or decision["nextPin"] != PIN:
        raise CheckError("canonical pin moved before implementation and certification")
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


def verify_checkout(manifest: dict[str, Any], commits: list[dict[str, str]],
                    paths: list[dict[str, str]], checkout: Path) -> None:
    if git(checkout, "rev-parse", "HEAD") != TARGET:
        raise CheckError(f"Hermes checkout must be exact target {TARGET}")
    git(checkout, "merge-base", "--is-ancestor", BASE, TARGET)
    actual_commits = git(checkout, "rev-list", "--reverse", f"{BASE}..{TARGET}").splitlines()
    if actual_commits != [row["commit"] for row in commits]:
        raise CheckError("exact commit inventory drift")
    for row in commits:
        actual = git(checkout, "show", "-s", "--format=%P%x09%s", row["commit"])
        if actual != f"{row['parents']}\t{row['subject']}":
            raise CheckError(f"commit metadata drift: {row['commit']}")
    actual_paths = []
    for raw in git(checkout, "diff", "--name-status", BASE, TARGET).splitlines():
        fields = raw.split("\t")
        actual_paths.append((fields[0], fields[-1]))
    if actual_paths != [(row["status"], row["path"]) for row in paths]:
        raise CheckError("exact changed-path inventory drift")
    additions = deletions = 0
    for raw in git(checkout, "diff", "--numstat", BASE, TARGET).splitlines():
        added, deleted, _ = raw.split("\t", 2)
        additions += 0 if added == "-" else int(added)
        deletions += 0 if deleted == "-" else int(deleted)
    if additions != manifest["range"]["additions"] or deletions != manifest["range"]["deletions"]:
        raise CheckError("range line-count drift")
    for row in manifest["authorityFiles"]:
        base_hash = hashlib.sha256(subprocess.run(
            ["git", "-C", str(checkout), "show", f"{BASE}:{row['path']}"],
            check=True, capture_output=True, timeout=60,
        ).stdout).hexdigest()
        target_hash = hashlib.sha256(subprocess.run(
            ["git", "-C", str(checkout), "show", f"{TARGET}:{row['path']}"],
            check=True, capture_output=True, timeout=60,
        ).stdout).hexdigest()
        if base_hash != row["baseSha256"] or target_hash != row["targetSha256"]:
            raise CheckError(f"authority digest drift: {row['path']}")


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
        print(f"Hermes 1bbb6e5..02c7ae9 audit failed: {error}", file=sys.stderr)
        return 1
    suffix = ", exact checkout" if arguments.checkout else ""
    print(f"Hermes 1bbb6e5..02c7ae9 audit passed: 3 commits, 6 paths, no new client work{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
