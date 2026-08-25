#!/usr/bin/env python3
"""Validate the exact every-parent Hermes gateway/platform delta ledger."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_METADATA = ROOT / "parity" / "hermes-gateway-platform-delta-40643cba-057dcdf.json"
EXPECTED_REPOSITORY = "https://github.com/nousresearch/hermes-agent.git"
EXPECTED_BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
EXPECTED_TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
EXPECTED_SCOPE = "gateway"
EXPECTED_EXCLUSIONS = ["fixture", "fixtures", "generated", "test", "tests"]
EXPECTED_PR95_HEAD = "887de277b1ea9b9f2860b85e9e38b5fe8b2e8971"
PINNED_LEDGER_HEADS = {
    "authority": "879078e3ef54d1af2d6e0208105c0cf93c71979c",
    "client-wire": "69d066bd3c213b8de69fa78735f20327f05f7123",
    "core-runtime": "7e46a9ab4e68f4f74ecc68fe2222798883a66091",
}
FIELDS = ["commit", "paths", "cluster", "classification", "disposition", "contract", "evidence", "required"]
CLASSIFICATIONS = {"portable-mobile-contract", "gateway-host-runtime", "merge-integration"}
DISPOSITIONS = {"covered-current-talaria", "host-only", "verify-on-host", "merge-integration"}
REF_DISPOSITIONS = {
    "authority": "covered-by-authority-crossref",
    "client-wire": "covered-by-client-wire-crossref",
    "core-runtime": "covered-by-core-runtime-crossref",
}
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")


class CheckError(RuntimeError):
    pass


def _git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(["git", "-C", str(checkout), *arguments], check=True,
                                capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout.strip()


def _git_bytes(checkout: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(["git", "-C", str(checkout), *arguments], check=True,
                                capture_output=True, timeout=90)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise CheckError(f"git {' '.join(arguments)} failed: {detail.strip()}") from error
    return result.stdout


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CheckError("metadata root must be an object")
    return value


def _read_tsv(path: Path) -> list[dict[str, str]]:
    try:
        reader = csv.DictReader(io.StringIO(path.read_text(encoding="utf-8")), delimiter="\t")
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if reader.fieldnames != FIELDS:
        raise CheckError(f"TSV columns must be: {', '.join(FIELDS)}")
    return list(reader)


def _safe_path(raw: object) -> str:
    value = str(raw)
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts:
        raise CheckError(f"unsafe path: {value}")
    return value


def _scoped(paths: list[str], exclusions: set[str]) -> list[str]:
    return sorted({path for path in paths if path.startswith("gateway/") and not set(Path(path).parts) & exclusions})


def _validate_assertions(assertions: object, field: str) -> None:
    if not isinstance(assertions, list) or not assertions:
        raise CheckError(f"{field} must be a non-empty list")
    for item in assertions:
        if not isinstance(item, dict) or set(item) != {"path", "contains"}:
            raise CheckError(f"invalid {field} entry")
        _safe_path(item["path"])
        if not str(item["contains"]).strip():
            raise CheckError(f"empty {field} assertion")


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "scopeRoot",
        "excludedPathComponents", "scopedCommitCount", "entryCount", "entriesFile",
        "clusterCounts", "classificationCounts", "dispositionCounts", "historyPathUnion",
        "finalNetFiles", "crossReferenceHeads", "crossReferenceCounts", "crossReferences",
        "talariaSlices", "sourceAssertions", "talariaAssertions",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    if metadata["repository"] != EXPECTED_REPOSITORY or metadata["baseCommit"] != EXPECTED_BASE or metadata["targetCommit"] != EXPECTED_TARGET:
        raise CheckError("upstream repository/range must retain exact audited endpoints")
    if metadata["scopeRoot"] != EXPECTED_SCOPE or metadata["excludedPathComponents"] != EXPECTED_EXCLUSIONS:
        raise CheckError("gateway production scope drift")
    if metadata["scopedCommitCount"] != 82 or metadata["entryCount"] != 48:
        raise CheckError("exact inventory count drift")
    entries_file = _safe_path(metadata["entriesFile"])
    entries = _read_tsv(metadata_path.parent / entries_file)
    if len(entries) != 48:
        raise CheckError("entryCount does not match TSV")

    history = metadata["historyPathUnion"]
    if not isinstance(history, list) or history != sorted(set(history)) or len(history) != 43:
        raise CheckError("historyPathUnion drift")
    history_set = set(history)
    seen: set[str] = set()
    for row in entries:
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen:
            raise CheckError(f"invalid or duplicate commit: {commit}")
        seen.add(commit)
        paths = row["paths"].split(";")
        if paths != sorted(set(paths)) or not paths or not set(paths) <= history_set:
            raise CheckError(f"invalid paths for {commit}")
        if row["classification"] not in CLASSIFICATIONS or row["disposition"] not in DISPOSITIONS:
            raise CheckError(f"invalid classification/disposition for {commit}")
        if row["classification"] == "merge-integration" and row["disposition"] != "merge-integration":
            raise CheckError(f"merge row disposition drift for {commit}")
        if any(not row[field].strip() for field in FIELDS[2:]):
            raise CheckError(f"empty semantic field for {commit}")
    for field, key in (("clusterCounts", "cluster"), ("classificationCounts", "classification"), ("dispositionCounts", "disposition")):
        if metadata[field] != dict(Counter(row[key] for row in entries)):
            raise CheckError(f"{field} drift")

    heads = metadata["crossReferenceHeads"]
    if heads != PINNED_LEDGER_HEADS:
        raise CheckError("crossReferenceHeads drift")
    refs = metadata["crossReferences"]
    if not isinstance(refs, list) or len(refs) != 34 or metadata["crossReferenceCounts"] != {"authority": 3, "client-wire": 21, "core-runtime": 10}:
        raise CheckError("cross-reference partition drift")
    ref_seen: set[str] = set()
    ref_counts: Counter[str] = Counter()
    for row in refs:
        if set(row) != {"commit", "paths", "ledger", "ledgerHead", "ledgerCluster", "classification", "disposition"}:
            raise CheckError("cross-reference schema drift")
        ledger = row["ledger"]
        if ledger not in PINNED_LEDGER_HEADS or row["ledgerHead"] != PINNED_LEDGER_HEADS[ledger]:
            raise CheckError("cross-reference ledger head drift")
        if row["classification"] != "predecessor-owned" or row["disposition"] != REF_DISPOSITIONS[ledger]:
            raise CheckError("cross-reference classification drift")
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen or commit in ref_seen:
            raise CheckError(f"cross-reference duplicate/invalid commit: {commit}")
        paths = row["paths"]
        if paths != sorted(set(paths)) or not paths or not set(paths) <= history_set or not str(row["ledgerCluster"]).strip():
            raise CheckError(f"invalid cross-reference paths/cluster for {commit}")
        ref_seen.add(commit); ref_counts[ledger] += 1
    if dict(ref_counts) != metadata["crossReferenceCounts"] or len(seen | ref_seen) != 82:
        raise CheckError("inventory partition does not cover 82 commits")

    net = metadata["finalNetFiles"]
    if not isinstance(net, list) or len(net) != 22 or [x["path"] for x in net] != sorted(x["path"] for x in net):
        raise CheckError("finalNetFiles drift")
    for row in net:
        if set(row) != {"path", "baseSha256", "targetSha256"} or row["path"] not in history_set:
            raise CheckError("invalid finalNetFiles row")
        for key in ("baseSha256", "targetSha256"):
            if row[key] != "absent" and not SHA64.fullmatch(row[key]):
                raise CheckError("invalid endpoint hash")
    slices = metadata["talariaSlices"]
    if not isinstance(slices, list) or len(slices) != 1 or slices[0].get("head") != EXPECTED_PR95_HEAD or slices[0].get("status") != "implemented-unmerged-live-device-proof-open":
        raise CheckError("PR95 slice status/head drift")
    _validate_assertions(metadata["sourceAssertions"], "sourceAssertions")
    _validate_assertions(metadata["talariaAssertions"], "talariaAssertions")
    return metadata, entries


def _blob_hash(checkout: Path, endpoint: str, path: str) -> str:
    try:
        value = _git_bytes(checkout, "show", f"{endpoint}:{path}")
    except CheckError as error:
        if "does not exist" in str(error) or "exists on disk" in str(error):
            return "absent"
        raise
    return hashlib.sha256(value).hexdigest()


def _verify_assertions(checkout: Path, endpoint: str, assertions: list[dict[str, str]], label: str) -> None:
    for assertion in assertions:
        source = _git_bytes(checkout, "show", f"{endpoint}:{assertion['path']}").decode(errors="replace")
        if assertion["contains"] not in source:
            raise CheckError(f"{label} source assertion drift: {assertion['path']}")


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path, *, verify_talaria: bool = True) -> None:
    base, target = metadata["baseCommit"], metadata["targetCommit"]
    _git(checkout, "cat-file", "-e", f"{base}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{target}^{{commit}}")
    exclusions = set(metadata["excludedPathComponents"])
    actual: dict[str, list[str]] = {}
    for commit in _git(checkout, "rev-list", "--reverse", f"{base}..{target}").splitlines():
        paths: set[str] = set()
        for parent in _git(checkout, "show", "-s", "--format=%P", commit).split():
            changed = _git(checkout, "diff", "--name-only", parent, commit, "--", metadata["scopeRoot"]).splitlines()
            paths.update(_scoped(changed, exclusions))
        if paths:
            actual[commit] = sorted(paths)
    expected = {row["commit"]: row["paths"].split(";") for row in entries}
    expected.update({row["commit"]: row["paths"] for row in metadata["crossReferences"]})
    if actual != expected:
        raise CheckError("every-parent gateway inventory drift")
    if sorted({path for paths in actual.values() for path in paths}) != metadata["historyPathUnion"]:
        raise CheckError("history path union drift")
    final_paths = _scoped(_git(checkout, "diff", "--name-only", f"{base}..{target}", "--", metadata["scopeRoot"]).splitlines(), exclusions)
    if final_paths != [row["path"] for row in metadata["finalNetFiles"]]:
        raise CheckError("final endpoint file set drift")
    for row in metadata["finalNetFiles"]:
        if _blob_hash(checkout, base, row["path"]) != row["baseSha256"] or _blob_hash(checkout, target, row["path"]) != row["targetSha256"]:
            raise CheckError(f"endpoint hash drift: {row['path']}")
    _verify_assertions(checkout, target, metadata["sourceAssertions"], "upstream")
    if verify_talaria:
        head = metadata["talariaSlices"][0]["head"]
        _git(ROOT, "cat-file", "-e", f"{head}^{{commit}}")
        _verify_assertions(ROOT, head, metadata["talariaAssertions"], "Talaria PR95")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--checkout", type=Path)
    parser.add_argument("--skip-talaria-head", action="store_true")
    args = parser.parse_args()
    try:
        metadata, entries = load(args.metadata)
        if args.checkout:
            verify_checkout(metadata, entries, args.checkout, verify_talaria=not args.skip_talaria_head)
    except CheckError as error:
        print(f"gateway/platform delta check failed: {error}", file=sys.stderr)
        return 1
    print(f"gateway/platform delta check passed: {len(entries)} owned + {len(metadata['crossReferences'])} predecessor = {metadata['scopedCommitCount']} commits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
