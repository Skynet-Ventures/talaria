#!/usr/bin/env python3
"""Validate the bounded Hermes authority-file delta ledger."""

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
DEFAULT_METADATA = ROOT / "parity" / "hermes-authority-delta-40643cba-057dcdf.json"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
FIELDS = ["commit", "paths", "cluster", "disposition", "contract", "evidence", "required"]
DISPOSITIONS = {
    "portable-implemented-live-proof",
    "portable-gap",
    "gateway-owned-live-proof",
    "desktop-only",
    "merge-integration",
    "test-only",
    "superseded",
}


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
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout.strip()


def _git_bytes(checkout: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit",
        "entryCount", "entriesFile", "clusterCounts", "authorityFiles",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    for key in ("baseCommit", "targetCommit"):
        if not SHA40.fullmatch(str(metadata[key])):
            raise CheckError(f"{key} must be one lowercase full SHA")
    if not isinstance(metadata["entryCount"], int) or metadata["entryCount"] <= 0:
        raise CheckError("entryCount must be a positive integer")
    cluster_counts = metadata["clusterCounts"]
    if not isinstance(cluster_counts, dict) or not cluster_counts or any(
        not isinstance(key, str) or not key or not isinstance(count, int) or count <= 0
        for key, count in cluster_counts.items()
    ):
        raise CheckError("clusterCounts must map nonempty names to positive integers")
    if sum(cluster_counts.values()) != metadata["entryCount"]:
        raise CheckError("clusterCounts must sum to entryCount")
    authority = metadata["authorityFiles"]
    if not isinstance(authority, list) or not authority:
        raise CheckError("authorityFiles must be a nonempty list")
    authority_paths: set[str] = set()
    for row in authority:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("authority file rows have unexpected fields")
        path = str(row["path"])
        relative = Path(path)
        if relative.is_absolute() or ".." in relative.parts or path in authority_paths:
            raise CheckError(f"unsafe or duplicate authority path: {path}")
        authority_paths.add(path)
        if not SHA64.fullmatch(str(row["baseSha256"])) or not SHA64.fullmatch(str(row["targetSha256"])):
            raise CheckError(f"invalid authority hash for {path}")

    entries_path = metadata_path.parent / str(metadata["entriesFile"])
    try:
        with entries_path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if reader.fieldnames != FIELDS:
                raise CheckError(f"ledger columns must be: {', '.join(FIELDS)}")
            entries = list(reader)
    except OSError as error:
        raise CheckError(f"cannot read {entries_path}: {error}") from error
    if len(entries) != metadata["entryCount"]:
        raise CheckError(f"entry count mismatch: metadata={metadata['entryCount']} ledger={len(entries)}")
    seen: set[str] = set()
    for row in entries:
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen:
            raise CheckError(f"invalid or duplicate commit: {commit}")
        seen.add(commit)
        paths = row["paths"].split(";")
        if not paths or len(paths) != len(set(paths)) or not set(paths) <= authority_paths:
            raise CheckError(f"invalid paths for {commit}: {row['paths']}")
        if row["disposition"] not in DISPOSITIONS:
            raise CheckError(f"invalid disposition for {commit}: {row['disposition']}")
        if any(not row[field].strip() for field in FIELDS[2:]):
            raise CheckError(f"empty semantic field for {commit}")
    actual_clusters = Counter(row["cluster"] for row in entries)
    if dict(sorted(actual_clusters.items())) != dict(sorted(cluster_counts.items())):
        raise CheckError(
            f"cluster counts drift: expected={metadata['clusterCounts']} actual={dict(actual_clusters)}"
        )
    return metadata, entries


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path) -> None:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    _git(checkout, "cat-file", "-e", f"{base}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{target}^{{commit}}")
    expected_paths: dict[str, set[str]] = {}
    for authority in metadata["authorityFiles"]:
        path = str(authority["path"])
        output = _git(checkout, "log", "--format=%H", f"{base}..{target}", "--", path)
        for commit in output.splitlines():
            expected_paths.setdefault(commit, set()).add(path)
        for endpoint, field in ((base, "baseSha256"), (target, "targetSha256")):
            body = _git_bytes(checkout, "show", f"{endpoint}:{path}")
            actual = hashlib.sha256(body).hexdigest()
            if actual != authority[field]:
                raise CheckError(f"{field} drift for {path}: expected {authority[field]}, actual {actual}")
    actual_paths = {row["commit"]: set(row["paths"].split(";")) for row in entries}
    missing = sorted(expected_paths.keys() - actual_paths.keys())
    extra = sorted(actual_paths.keys() - expected_paths.keys())
    mismatched = sorted(
        commit for commit in expected_paths.keys() & actual_paths.keys()
        if expected_paths[commit] != actual_paths[commit]
    )
    if missing or extra or mismatched:
        raise CheckError(
            "authority commit coverage drift: "
            f"missing={missing}, extra={extra}, path_mismatch={mismatched}"
        )


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
        print(f"Hermes authority delta check failed: {error}", file=sys.stderr)
        return 1
    detail = ", exact checkout" if arguments.checkout else ""
    print(f"Hermes authority delta check passed: {len(entries)} commits{detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
