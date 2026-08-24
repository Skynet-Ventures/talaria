#!/usr/bin/env python3
"""Validate the bounded Hermes core-runtime parity ledger.

The ledger intentionally uses a fixed endpoint manifest rather than broad
directory globs.  Its inventory walks every reachable commit in the pinned
upstream range and unions every parent diff for merge commits.
"""

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
DEFAULT_METADATA = ROOT / "parity" / "hermes-core-runtime-delta-40643cba-057dcdf.json"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
EXPECTED_TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
EXPECTED_REPOSITORY = "https://github.com/nousresearch/hermes-agent.git"
EXACT_SCOPE_PATHS = [
    "agent/agent_runtime_helpers.py",
    "agent/background_review.py",
    "agent/codex_runtime.py",
    "agent/context_compressor.py",
    "agent/conversation_compression.py",
    "agent/conversation_loop.py",
    "agent/error_classifier.py",
    "agent/error_surface.py",
    "agent/gemini_native_adapter.py",
    "agent/interrupt_compat.py",
    "agent/message_sanitization.py",
    "agent/native_compaction.py",
    "agent/review_engine.py",
    "agent/subagent_lifecycle.py",
    "agent/tool_dispatch_helpers.py",
    "agent/tool_executor.py",
    "agent/turn_context.py",
    "agent/turn_finalizer.py",
    "cron/jobs.py",
    "cron/scheduler.py",
    "cron/scheduler_provider.py",
    "run_agent.py",
    "tools/code_execution_tool.py",
    "tools/cronjob_tools.py",
    "tools/delegate_tool.py",
    "tools/interrupt.py",
    "tools/mcp_tool.py",
    "tools/process_registry.py",
    "tools/registry.py",
    "tools/terminal_tool.py",
]
FIELDS = [
    "commit", "paths", "cluster", "classification", "disposition",
    "talariaSlice", "contract", "evidence", "required",
]
AUTHORITY_FIELDS = [
    "commit", "paths", "cluster", "disposition", "contract", "evidence", "required",
]
CLIENT_WIRE_FIELDS = [
    "commit", "paths", "cluster", "disposition", "impact",
    "contract", "evidence", "required",
]

PINNED_LEDGER_HEADS = {
    "authority": {
        "ledgerFile": "parity/hermes-authority-delta-40643cba-057dcdf.tsv",
        "head": "879078e3ef54d1af2d6e0208105c0cf93c71979c",
        "fields": AUTHORITY_FIELDS,
    },
    "client-wire": {
        "ledgerFile": "parity/hermes-client-wire-delta-40643cba-057dcdf.tsv",
        "head": "69d066bd3c213b8de69fa78735f20327f05f7123",
        "fields": CLIENT_WIRE_FIELDS,
    },
}
OPEN_SLICE_HEADS = {
    "rich-transcript-hydration": (
        "codex/rich-transcript-hydration",
        "d5bad705f1c19d716eea4abb8de1ba4206659dde",
    ),
    "rich-transcript-structured-output": (
        "codex/rich-transcript-structured-output",
        "fdee839fdc1fda8a4a8233ff5e459795d09752b0",
    ),
    "subagent-live-presentation": (
        "codex/subagent-live-presentation",
        "07e3c68c6d2010edb00fd63414b31c878af2b8d2",
    ),
    "error-surface-v2": (
        "codex/current-hermes-error-surface-v2",
        "928205afd3e5f9a708f462a55b2613ee6633f3ae",
    ),
    "cron-push-isolation": (
        "codex/current-hermes-cron-push-isolation",
        "28e9f713e4aa46fc78fbaa1ef19abf0892ff3c8e",
    ),
    "mobile-gateway-pty": (
        "codex/mobile-gateway-pty",
        "c7f64a6462d7e2c19a6714eca7d0fe8c5de4f699",
    ),
}
CLASSIFICATIONS = {
    "portable-mobile-runtime",
    "upstream-contract",
    "gateway-host-runtime",
    "desktop-host-runtime",
    "desktop-only",
    "merge-integration",
    "test-only",
}
DISPOSITIONS = {
    "covered-by-open-slice",
    "upstream-contract-blocked",
    "host-only",
    "desktop-only",
    "merge-integration",
    "superseded",
    "test-only",
    "verify-on-host",
}
REF_DISPOSITIONS = {"covered-by-pr85-crossref", "covered-by-pr90-crossref"}


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


def _local_git(*arguments: str) -> str:
    return _git(ROOT, *arguments)


def _safe_path(raw: object) -> str:
    value = str(raw)
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts:
        raise CheckError(f"unsafe path: {value}")
    return value


def _read_tsv_text(text: str, fields: list[str], name: str) -> list[dict[str, str]]:
    reader = csv.DictReader(io.StringIO(text), delimiter="\t")
    if reader.fieldnames != fields:
        raise CheckError(f"{name} columns must be: {', '.join(fields)}")
    return list(reader)


def _read_tsv(path: Path, fields: list[str]) -> list[dict[str, str]]:
    try:
        return _read_tsv_text(path.read_text(encoding="utf-8"), fields, str(path))
    except OSError as error:
        raise CheckError(f"cannot read {path}: {error}") from error


def _validate_counter(value: object, expected: Counter[str], field: str) -> None:
    if not isinstance(value, dict) or value != dict(expected):
        raise CheckError(f"{field} drift")


def _validate_row(row: dict[str, str], history_paths: set[str], slice_ids: set[str]) -> None:
    commit = row["commit"]
    if not SHA40.fullmatch(commit):
        raise CheckError(f"invalid commit: {commit}")
    paths = row["paths"].split(";")
    if paths != sorted(set(paths)) or not paths or not set(paths) <= history_paths:
        raise CheckError(f"invalid paths for {commit}")
    classification = row["classification"]
    disposition = row["disposition"]
    if classification not in CLASSIFICATIONS:
        raise CheckError(f"invalid classification for {commit}")
    if disposition not in DISPOSITIONS:
        raise CheckError(f"invalid disposition for {commit}")
    slice_id = row["talariaSlice"]
    if slice_id != "none" and slice_id not in slice_ids:
        raise CheckError(f"unknown Talaria slice for {commit}")
    if disposition == "covered-by-open-slice":
        if classification != "portable-mobile-runtime" or slice_id == "none":
            raise CheckError(f"invalid open-slice disposition for {commit}")
    elif slice_id != "none":
        raise CheckError(f"non-covered row names Talaria slice for {commit}")
    if disposition == "upstream-contract-blocked" and classification != "upstream-contract":
        raise CheckError(f"invalid blocked classification for {commit}")
    if disposition == "host-only" and classification not in {"gateway-host-runtime", "desktop-host-runtime"}:
        raise CheckError(f"invalid host-only classification for {commit}")
    if disposition == "desktop-only" and classification not in {"desktop-host-runtime", "desktop-only"}:
        raise CheckError(f"invalid desktop-only classification for {commit}")
    if disposition == "merge-integration" and classification != "merge-integration":
        raise CheckError(f"invalid merge classification for {commit}")
    if disposition == "test-only" and classification != "test-only":
        raise CheckError(f"invalid test classification for {commit}")
    if any(not row[field].strip() for field in FIELDS[2:]):
        raise CheckError(f"empty semantic field for {commit}")


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "scopePaths",
        "scopeCorrection", "scopedCommitCount", "entryCount", "entriesFile",
        "clusterCounts", "classificationCounts", "dispositionCounts", "historyPathUnion",
        "finalNetFiles", "crossReferenceHeads", "crossReferenceCounts",
        "crossReferences", "openTalariaSlices", "sourceAssertions",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    for key in ("baseCommit", "targetCommit"):
        if not SHA40.fullmatch(str(metadata[key])):
            raise CheckError(f"{key} must be one lowercase full SHA")
    if metadata["repository"] != EXPECTED_REPOSITORY:
        raise CheckError("repository must retain the pinned Hermes upstream")
    if metadata["baseCommit"] != EXPECTED_BASE or metadata["targetCommit"] != EXPECTED_TARGET:
        raise CheckError("upstream range must retain the exact audited endpoints")

    scope = metadata["scopePaths"]
    if not isinstance(scope, list) or scope != EXACT_SCOPE_PATHS:
        raise CheckError("scopePaths must retain the sorted exact 30-path manifest")
    for path in scope:
        _safe_path(path)
    correction = metadata["scopeCorrection"]
    if not isinstance(correction, dict) or set(correction) != {
        "reportedPathCount", "actualPathCount", "reason",
    } or correction["reportedPathCount"] != 31 or correction["actualPathCount"] != 30 or not correction["reason"]:
        raise CheckError("scope correction must retain the 31-to-30 accounting correction")
    if metadata["scopedCommitCount"] != 112 or metadata["entryCount"] != 94:
        raise CheckError("bounded inventory must remain 30 paths / 112 scoped / 94 new commits")

    history_paths = metadata["historyPathUnion"]
    if history_paths != scope:
        raise CheckError("historyPathUnion must exactly equal the scope manifest")
    net_files = metadata["finalNetFiles"]
    if not isinstance(net_files, list) or not net_files:
        raise CheckError("finalNetFiles must be nonempty")
    net_paths: list[str] = []
    for row in net_files:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("final net rows have unexpected fields")
        net_paths.append(_safe_path(row["path"]))
        for field in ("baseSha256", "targetSha256"):
            digest = str(row[field])
            if digest != "absent" and not SHA64.fullmatch(digest):
                raise CheckError(f"invalid {field} for {row['path']}")
    if net_paths != sorted(set(net_paths)) or not set(net_paths) <= set(scope):
        raise CheckError("finalNetFiles paths must be sorted exact scope paths")

    pinned = metadata["crossReferenceHeads"]
    if not isinstance(pinned, dict) or set(pinned) != set(PINNED_LEDGER_HEADS):
        raise CheckError("crossReferenceHeads must retain both predecessor ledgers")
    for ledger, expected in PINNED_LEDGER_HEADS.items():
        value = pinned[ledger]
        if not isinstance(value, dict) or value != {
            "ledgerFile": expected["ledgerFile"], "head": expected["head"],
        }:
            raise CheckError(f"pinned {ledger} ledger head drift")
    if metadata["crossReferenceCounts"] != {"authority": 7, "client-wire": 11}:
        raise CheckError("cross-reference counts must retain PR85=7 and PR90=11")

    open_slices = metadata["openTalariaSlices"]
    if not isinstance(open_slices, list) or len(open_slices) != len(OPEN_SLICE_HEADS):
        raise CheckError("open Talaria slice inventory drift")
    slice_ids: set[str] = set()
    for row in open_slices:
        if not isinstance(row, dict) or set(row) != {"id", "branch", "head", "coverage"}:
            raise CheckError("open Talaria slice row has unexpected fields")
        slice_id = str(row["id"])
        if slice_id in slice_ids or slice_id not in OPEN_SLICE_HEADS:
            raise CheckError(f"invalid open Talaria slice: {slice_id}")
        slice_ids.add(slice_id)
        branch, head = OPEN_SLICE_HEADS[slice_id]
        if row["branch"] != branch or row["head"] != head:
            raise CheckError(f"open Talaria slice head drift: {slice_id}")
        if not isinstance(row["coverage"], list) or not row["coverage"]:
            raise CheckError(f"open Talaria slice coverage missing: {slice_id}")
    if slice_ids != set(OPEN_SLICE_HEADS):
        raise CheckError("open Talaria slice set drift")

    entries_path = metadata_path.parent / _safe_path(metadata["entriesFile"])
    entries = _read_tsv(entries_path, FIELDS)
    if len(entries) != metadata["entryCount"]:
        raise CheckError("entry count mismatch")
    seen: set[str] = set()
    history_set = set(history_paths)
    for row in entries:
        if row["commit"] in seen:
            raise CheckError(f"invalid or duplicate commit: {row['commit']}")
        seen.add(row["commit"])
        _validate_row(row, history_set, slice_ids)
    _validate_counter(metadata["clusterCounts"], Counter(row["cluster"] for row in entries), "clusterCounts")
    _validate_counter(metadata["classificationCounts"], Counter(row["classification"] for row in entries), "classificationCounts")
    _validate_counter(metadata["dispositionCounts"], Counter(row["disposition"] for row in entries), "dispositionCounts")

    refs = metadata["crossReferences"]
    if not isinstance(refs, list) or len(refs) != sum(metadata["crossReferenceCounts"].values()):
        raise CheckError("cross-reference count mismatch")
    ref_seen: set[str] = set()
    ref_counts: Counter[str] = Counter()
    for row in refs:
        fields = {"commit", "paths", "ledger", "ledgerHead", "ledgerCluster", "classification", "disposition"}
        if not isinstance(row, dict) or set(row) != fields:
            raise CheckError("cross-reference row has unexpected fields")
        commit = str(row["commit"])
        ledger = str(row["ledger"])
        if not SHA40.fullmatch(commit) or commit in ref_seen or commit in seen or ledger not in PINNED_LEDGER_HEADS:
            raise CheckError(f"invalid cross-reference: {commit}")
        ref_seen.add(commit)
        ref_counts[ledger] += 1
        if row["ledgerHead"] != PINNED_LEDGER_HEADS[ledger]["head"] or not str(row["ledgerCluster"]):
            raise CheckError(f"cross-reference ledger head/cluster drift: {commit}")
        paths = row["paths"]
        if not isinstance(paths, list) or paths != sorted(set(paths)) or not paths or not set(paths) <= history_set:
            raise CheckError(f"invalid cross-reference paths for {commit}")
        if row["classification"] not in CLASSIFICATIONS:
            raise CheckError(f"invalid cross-reference classification: {commit}")
        expected_disposition = "covered-by-pr85-crossref" if ledger == "authority" else "covered-by-pr90-crossref"
        if row["disposition"] != expected_disposition or row["disposition"] not in REF_DISPOSITIONS:
            raise CheckError(f"invalid cross-reference disposition: {commit}")
    if dict(ref_counts) != metadata["crossReferenceCounts"]:
        raise CheckError("cross-reference partition count drift")

    assertions = metadata["sourceAssertions"]
    if not isinstance(assertions, list) or len(assertions) < 3:
        raise CheckError("sourceAssertions must retain the one-shot evidence")
    for row in assertions:
        if not isinstance(row, dict) or set(row) != {"path", "contains", "description"}:
            raise CheckError("source assertion row has unexpected fields")
        if _safe_path(row["path"]) not in history_set or not row["contains"] or not row["description"]:
            raise CheckError("invalid source assertion")
    return metadata, entries


def _scoped_inventory(metadata: dict[str, Any], checkout: Path) -> tuple[list[str], dict[str, set[str]]]:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    scope = [str(path) for path in metadata["scopePaths"]]
    scope_set = set(scope)
    candidates = _git(checkout, "rev-list", "--reverse", f"{base}..{target}").splitlines()
    commits: list[str] = []
    paths_by_commit: dict[str, set[str]] = {}
    for commit in candidates:
        parents = _git(checkout, "show", "-s", "--format=%P", commit).split()
        changed: set[str] = set()
        for parent in parents:
            changed.update(_git(checkout, "diff", "--name-only", parent, commit, "--", *scope).splitlines())
        changed &= scope_set
        if changed:
            commits.append(commit)
            paths_by_commit[commit] = changed
    return commits, paths_by_commit


def _blob_hash(checkout: Path, commit: str, path: str) -> str:
    present = _git(checkout, "ls-tree", "--name-only", commit, "--", path)
    if present != path:
        return "absent"
    return hashlib.sha256(_git_bytes(checkout, "show", f"{commit}:{path}")).hexdigest()


def _pinned_ledger_rows(metadata: dict[str, Any]) -> dict[str, dict[str, dict[str, str]]]:
    result: dict[str, dict[str, dict[str, str]]] = {}
    for ledger, expected in PINNED_LEDGER_HEADS.items():
        pin = metadata["crossReferenceHeads"][ledger]
        _local_git("cat-file", "-e", f"{pin['head']}^{{commit}}")
        text = _local_git("show", f"{pin['head']}:{pin['ledgerFile']}")
        rows = _read_tsv_text(text, expected["fields"], f"{ledger} ledger at {pin['head']}")
        result[ledger] = {row["commit"]: row for row in rows}
    return result


def _verify_open_slice_heads(metadata: dict[str, Any]) -> None:
    for row in metadata["openTalariaSlices"]:
        actual = _local_git("show-ref", "--verify", "--hash", f"refs/heads/{row['branch']}")
        if actual != row["head"]:
            raise CheckError(f"open Talaria slice ref drift: {row['id']}")


def _verify_source_assertions(metadata: dict[str, Any], checkout: Path) -> None:
    target = str(metadata["targetCommit"])
    for row in metadata["sourceAssertions"]:
        body = _git_bytes(checkout, "show", f"{target}:{row['path']}").decode(errors="replace")
        if str(row["contains"]) not in body:
            raise CheckError(f"upstream source assertion drift: {row['path']}")


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

    ledgers = _pinned_ledger_rows(metadata)
    expected_ledger: dict[str, str] = {}
    for commit in commits:
        matches = [ledger for ledger, rows in ledgers.items() if commit in rows]
        if len(matches) > 1:
            raise CheckError(f"ambiguous predecessor ledger coverage: {commit}")
        if matches:
            expected_ledger[commit] = matches[0]
    refs = {row["commit"]: row for row in metadata["crossReferences"]}
    if set(refs) != set(expected_ledger):
        raise CheckError("predecessor cross-reference partition drift")
    entry_map = {row["commit"]: row for row in entries}
    if set(entry_map) != set(commits) - set(expected_ledger):
        raise CheckError("new core-runtime commit coverage drift")
    for commit in commits:
        expected_paths = paths_by_commit[commit]
        if commit in refs:
            ref = refs[commit]
            ledger = expected_ledger[commit]
            if ref["ledger"] != ledger or ref["ledgerCluster"] != ledgers[ledger][commit]["cluster"]:
                raise CheckError(f"predecessor ledger classification drift: {commit}")
            actual_paths = set(ref["paths"])
        else:
            actual_paths = set(entry_map[commit]["paths"].split(";"))
        if actual_paths != expected_paths:
            raise CheckError(f"merge-parent path union drift for {commit}")

    scope = [str(path) for path in metadata["scopePaths"]]
    net_paths = sorted(_git(checkout, "diff", "--name-only", f"{base}..{target}", "--", *scope).splitlines())
    net_rows = metadata["finalNetFiles"]
    if net_paths != [row["path"] for row in net_rows]:
        raise CheckError("final net tree drift")
    for row in net_rows:
        for endpoint, field in ((base, "baseSha256"), (target, "targetSha256")):
            if _blob_hash(checkout, endpoint, row["path"]) != row[field]:
                raise CheckError(f"{field} drift for {row['path']}")
    _verify_source_assertions(metadata, checkout)
    _verify_open_slice_heads(metadata)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--checkout", type=Path, help="exact Hermes upstream checkout")
    args = parser.parse_args(argv)
    try:
        metadata, entries = load(args.metadata)
        if args.checkout:
            verify_checkout(metadata, entries, args.checkout)
    except CheckError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"OK: {metadata['scopedCommitCount']} scoped commits, "
        f"{metadata['entryCount']} new rows, {len(metadata['crossReferences'])} predecessor crossrefs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
