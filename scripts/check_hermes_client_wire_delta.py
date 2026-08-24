#!/usr/bin/env python3
"""Validate the bounded current-Hermes client-wire delta ledger."""

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
DEFAULT_METADATA = ROOT / "parity" / "hermes-client-wire-delta-40643cba-057dcdf.json"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
FIELDS = [
    "commit", "paths", "cluster", "disposition", "impact",
    "contract", "evidence", "required",
]
DISPOSITIONS = {
    "portable-implemented-live-proof",
    "portable-implemented-open-pr-live-proof",
    "portable-gap",
    "gateway-owned-live-proof",
    "gateway-only",
    "dashboard-only",
    "desktop-only",
    "merge-integration",
    "superseded",
}
IMPACTS = {"request", "response", "event", "security", "none"}


class CheckError(RuntimeError):
    pass


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CheckError("metadata root must be an object")
    return value


def _git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, text=True, timeout=90,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout.strip()


def _git_bytes(checkout: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, timeout=90,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout


def _safe_path(raw: object) -> str:
    value = str(raw)
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts:
        raise CheckError(f"unsafe path: {value}")
    return value


def _read_tsv(path: Path, fields: list[str]) -> list[dict[str, str]]:
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if reader.fieldnames != fields:
                raise CheckError(f"ledger columns must be: {', '.join(fields)}")
            return list(reader)
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit",
        "scopePatterns", "scopedCommitCount", "entryCount", "entriesFile",
        "clusterCounts", "historyPathUnion", "finalNetFiles",
        "authorityLedgerFile", "authorityIntersectionCount", "crossReferences",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    for key in ("baseCommit", "targetCommit"):
        if not SHA40.fullmatch(str(metadata[key])):
            raise CheckError(f"{key} must be one lowercase full SHA")
    patterns = metadata["scopePatterns"]
    if not isinstance(patterns, list) or not patterns or any(
        not isinstance(item, str) or not item for item in patterns
    ):
        raise CheckError("scopePatterns must be nonempty strings")
    if metadata["scopedCommitCount"] != 71 or metadata["entryCount"] != 64:
        raise CheckError("bounded inventory must remain 71 scoped / 64 new commits")
    clusters = metadata["clusterCounts"]
    if not isinstance(clusters, dict) or sum(clusters.values()) != metadata["entryCount"]:
        raise CheckError("clusterCounts must sum to entryCount")
    history_paths = metadata["historyPathUnion"]
    if not isinstance(history_paths, list) or history_paths != sorted(set(history_paths)):
        raise CheckError("historyPathUnion must be sorted and unique")
    for path in history_paths:
        _safe_path(path)
    net_files = metadata["finalNetFiles"]
    if not isinstance(net_files, list) or len(net_files) != 12:
        raise CheckError("finalNetFiles must retain the exact 12-file net tree")
    net_paths: list[str] = []
    for row in net_files:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("final net rows have unexpected fields")
        net_paths.append(_safe_path(row["path"]))
        for field in ("baseSha256", "targetSha256"):
            digest = str(row[field])
            if digest != "absent" and not SHA64.fullmatch(digest):
                raise CheckError(f"invalid {field} for {row['path']}")
    if net_paths != sorted(set(net_paths)):
        raise CheckError("finalNetFiles paths must be sorted and unique")

    entries_path = metadata_path.parent / _safe_path(metadata["entriesFile"])
    entries = _read_tsv(entries_path, FIELDS)
    if len(entries) != metadata["entryCount"]:
        raise CheckError("entry count mismatch")
    seen: set[str] = set()
    for row in entries:
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen:
            raise CheckError(f"invalid or duplicate commit: {commit}")
        seen.add(commit)
        paths = row["paths"].split(";")
        if paths != sorted(set(paths)) or not set(paths) <= set(history_paths):
            raise CheckError(f"invalid paths for {commit}")
        if row["disposition"] not in DISPOSITIONS:
            raise CheckError(f"invalid disposition for {commit}")
        impacts = set(row["impact"].split(","))
        if not impacts or not impacts <= IMPACTS or ("none" in impacts and len(impacts) > 1):
            raise CheckError(f"invalid impact for {commit}")
        if any(not row[field].strip() for field in FIELDS[2:]):
            raise CheckError(f"empty semantic field for {commit}")
    if dict(Counter(row["cluster"] for row in entries)) != clusters:
        raise CheckError("cluster count drift")

    authority_path = ROOT / _safe_path(metadata["authorityLedgerFile"])
    authority_rows = _read_tsv(
        authority_path,
        ["commit", "paths", "cluster", "disposition", "contract", "evidence", "required"],
    )
    authority = {row["commit"]: row for row in authority_rows}
    refs = metadata["crossReferences"]
    if (
        not isinstance(refs, list)
        or len(refs) != metadata["authorityIntersectionCount"]
        or metadata["authorityIntersectionCount"] != 7
    ):
        raise CheckError("authority intersection must retain exactly 7 cross-references")
    ref_commits: set[str] = set()
    for row in refs:
        if not isinstance(row, dict) or set(row) != {"commit", "paths", "authorityCluster"}:
            raise CheckError("cross-reference row has unexpected fields")
        commit = str(row["commit"])
        if commit in ref_commits or commit not in authority or commit in seen:
            raise CheckError(f"invalid authority cross-reference: {commit}")
        ref_commits.add(commit)
        if row["authorityCluster"] != authority[commit]["cluster"]:
            raise CheckError(f"authority cluster drift for {commit}")
        paths = row["paths"]
        if not isinstance(paths, list) or paths != sorted(set(paths)):
            raise CheckError(f"invalid cross-reference paths for {commit}")
        if not set(paths).issubset(set(history_paths)):
            raise CheckError(f"cross-reference path outside history union for {commit}")
    return metadata, entries


def _scoped_inventory(metadata: dict[str, Any], checkout: Path) -> tuple[list[str], dict[str, set[str]]]:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    patterns = [str(item) for item in metadata["scopePatterns"]]
    output = _git(checkout, "log", "--reverse", "--format=%H", f"{base}..{target}", "--", *patterns)
    commits: list[str] = []
    seen: set[str] = set()
    for commit in output.splitlines():
        if commit and commit not in seen:
            commits.append(commit)
            seen.add(commit)
    paths_by_commit: dict[str, set[str]] = {}
    for commit in commits:
        parents = _git(checkout, "show", "-s", "--format=%P", commit).split()
        changed: set[str] = set()
        for parent in parents:
            changed.update(
                _git(checkout, "diff", "--name-only", parent, commit, "--", *patterns).splitlines()
            )
        paths_by_commit[commit] = {path for path in changed if path}
    return commits, paths_by_commit


def _blob_hash(checkout: Path, commit: str, path: str) -> str:
    present = _git(checkout, "ls-tree", "--name-only", commit, "--", path)
    if present != path:
        return "absent"
    body = _git_bytes(checkout, "show", f"{commit}:{path}")
    return hashlib.sha256(body).hexdigest()


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path) -> None:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    _git(checkout, "cat-file", "-e", f"{base}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{target}^{{commit}}")
    commits, paths_by_commit = _scoped_inventory(metadata, checkout)
    if len(commits) != metadata["scopedCommitCount"]:
        raise CheckError(f"scoped commit drift: {len(commits)}")
    actual_union = sorted(set().union(*paths_by_commit.values()))
    if actual_union != metadata["historyPathUnion"]:
        raise CheckError("history path union drift")

    authority_rows = _read_tsv(
        ROOT / str(metadata["authorityLedgerFile"]),
        ["commit", "paths", "cluster", "disposition", "contract", "evidence", "required"],
    )
    authority_commits = {row["commit"] for row in authority_rows}
    expected_refs = set(commits) & authority_commits
    refs = {row["commit"] for row in metadata["crossReferences"]}
    if refs != expected_refs:
        raise CheckError(f"authority intersection drift: expected={sorted(expected_refs)} actual={sorted(refs)}")
    entry_map = {row["commit"]: row for row in entries}
    expected_entries = set(commits) - expected_refs
    if set(entry_map) != expected_entries:
        raise CheckError("new wire commit coverage drift")
    ref_map = {row["commit"]: row for row in metadata["crossReferences"]}
    for commit in commits:
        expected_paths = paths_by_commit[commit]
        actual_paths = set(entry_map[commit]["paths"].split(";")) if commit in entry_map else set(ref_map[commit]["paths"])
        if actual_paths != expected_paths:
            raise CheckError(f"path union drift for {commit}")

    patterns = [str(item) for item in metadata["scopePatterns"]]
    net_paths = sorted(_git(checkout, "diff", "--name-only", f"{base}..{target}", "--", *patterns).splitlines())
    declared = [row["path"] for row in metadata["finalNetFiles"]]
    if net_paths != declared:
        raise CheckError("final net path drift")
    for row in metadata["finalNetFiles"]:
        for endpoint, field in ((base, "baseSha256"), (target, "targetSha256")):
            actual = _blob_hash(checkout, endpoint, row["path"])
            if actual != row[field]:
                raise CheckError(f"{field} drift for {row['path']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--checkout", type=Path)
    arguments = parser.parse_args()
    try:
        metadata, entries = load(arguments.metadata.resolve())
        if arguments.checkout:
            verify_checkout(metadata, entries, arguments.checkout.resolve())
    except CheckError as error:
        print(f"Hermes client-wire delta check failed: {error}", file=sys.stderr)
        return 1
    suffix = ", exact checkout" if arguments.checkout else ""
    print(f"Hermes client-wire delta check passed: {len(entries)} new + 7 cross-referenced commits{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
