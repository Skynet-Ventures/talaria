#!/usr/bin/env python3
"""Validate the exact non-web Hermes CLI delta inventory.

The inventory walks every reachable commit in the pinned range, unions every
parent diff for merges, and filters only the documented non-production web,
test, generated, and static paths.  The TSV is deliberately a full inventory:
predecessor-ledger references are evidence fields, not a reason to omit a
CLI-specific disposition such as one-shot re-arm.
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
DEFAULT_METADATA = ROOT / "parity" / "hermes-cli-delta-40643cba-057dcdf.json"
EXPECTED_REPOSITORY = "https://github.com/nousresearch/hermes-agent.git"
EXPECTED_BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
EXPECTED_TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")

FIELDS = [
    "commit", "paths", "cluster", "classification", "disposition",
    "talariaStatus", "predecessors",
]

SCOPE_RULES = {
    "root": "hermes_cli/",
    "excludeExact": [
        "hermes_cli/web_server.py",
        "hermes_cli/data/plugin_index.json",
        "hermes_cli/observability/schemas/hermes.shared_metrics.v2.schema.json",
    ],
    "excludePrefixes": [
        "hermes_cli/web_routers/",
        "hermes_cli/tests/",
        "hermes_cli/static/",
        "hermes_cli/generated/",
    ],
    "excludeTestRules": [
        "contains:/tests/",
        "basename-prefix:test_",
        "basename-suffix:_test.py",
    ],
}

PREDECESSOR_LEDGERS = {
    "authority": {
        "head": "879078e3ef54d1af2d6e0208105c0cf93c71979c",
        "entriesFile": "parity/hermes-authority-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "disposition", "contract", "evidence", "required"],
    },
    "client-wire": {
        "head": "69d066bd3c213b8de69fa78735f20327f05f7123",
        "entriesFile": "parity/hermes-client-wire-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "disposition", "impact", "contract", "evidence", "required"],
    },
    "core-runtime": {
        "head": "7e46a9ab4e68f4f74ecc68fe2222798883a66091",
        "entriesFile": "parity/hermes-core-runtime-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "classification", "disposition", "talariaSlice", "contract", "evidence", "required"],
    },
}

CLASSIFICATIONS = {
    "merge-integration",
    "gateway-host-runtime",
    "host-cli-runtime",
    "desktop-only",
    "dashboard-plugin-host",
    "portable-mobile-runtime",
    "portable-mobile-presentation",
    "upstream-contract",
    "durable-host-update-recovery",
    "predecessor-covered",
}
DISPOSITIONS = {
    "merge-integration",
    "host-cli-only",
    "desktop-only",
    "dynamic-catalog-already-consumed",
    "already-portable",
    "covered-by-predecessor",
    "covered-by-pr91-excluded",
    "merged-to-parent-not-main-uncertified",
    "upstream-contract-blocked",
    "verify-on-host",
}
TALARIA_STATUSES = {
    "none",
    "existing-model-options-consumer",
    "existing-generic-cron-delivery",
    "pr91-excluded",
    "pr94-parent-merged-not-main-uncertified",
}


class CheckError(RuntimeError):
    pass


def _git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, text=True, timeout=90,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {str(detail).strip()}") from error
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
        raise CheckError(f"git {' '.join(arguments)} failed: {str(detail).strip()}") from error
    return result.stdout


def _local_git(*arguments: str) -> str:
    return _git(ROOT, *arguments)


def _safe_path(value: object) -> str:
    path = str(value)
    candidate = Path(path)
    if not path or candidate.is_absolute() or ".." in candidate.parts:
        raise CheckError(f"unsafe path: {path}")
    return path


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CheckError("metadata root must be an object")
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


def _structurally_scoped(path: str) -> bool:
    if not path.startswith("hermes_cli/"):
        return False
    relative = path.removeprefix("hermes_cli/")
    if relative == "web_server.py" or relative.startswith("web_routers/"):
        return False
    if relative.startswith("tests/") or "/tests/" in relative:
        return False
    name = Path(relative).name
    return not name.startswith("test_") and not name.endswith("_test.py")


def _production_scoped(path: str) -> bool:
    if not _structurally_scoped(path):
        return False
    if path in set(SCOPE_RULES["excludeExact"][1:]):
        return False
    relative = path.removeprefix("hermes_cli/")
    return not relative.startswith(("static/", "generated/")) and "/static/" not in relative and "/generated/" not in relative


def _hash_paths(paths: list[str]) -> str:
    return hashlib.sha256(("\n".join(paths) + "\n").encode()).hexdigest()


def _inventory(metadata: dict[str, Any], checkout: Path) -> tuple[list[str], dict[str, set[str]], set[str]]:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    commits: list[str] = []
    paths_by_commit: dict[str, set[str]] = {}
    raw_paths: set[str] = set()
    for commit in _git(checkout, "rev-list", "--reverse", f"{base}..{target}").splitlines():
        parents = _git(checkout, "show", "-s", "--format=%P", commit).split()
        raw_changed: set[str] = set()
        production_changed: set[str] = set()
        for parent in parents:
            changed = _git(checkout, "diff", "--name-only", parent, commit, "--", "hermes_cli").splitlines()
            raw_changed.update(path for path in changed if _structurally_scoped(path))
            production_changed.update(path for path in changed if _production_scoped(path))
        raw_paths.update(raw_changed)
        if production_changed:
            commits.append(commit)
            paths_by_commit[commit] = production_changed
    return commits, paths_by_commit, raw_paths


def _blob_hash(checkout: Path, commit: str, path: str) -> str:
    if _git(checkout, "ls-tree", "--name-only", commit, "--", path) != path:
        return "absent"
    return hashlib.sha256(_git_bytes(checkout, "show", f"{commit}:{path}")).hexdigest()


def _validate_counter(value: object, expected: Counter[str], name: str) -> None:
    if not isinstance(value, dict) or value != dict(expected):
        raise CheckError(f"{name} drift")


def _validate_reference_metadata(metadata: dict[str, Any]) -> None:
    ledgers = metadata["predecessorLedgers"]
    if ledgers != {
        name: {"head": value["head"], "entriesFile": value["entriesFile"]}
        for name, value in PREDECESSOR_LEDGERS.items()
    }:
        raise CheckError("predecessor ledger pins drift")
    refs = metadata["talariaReferences"]
    if not isinstance(refs, list) or len(refs) != 2:
        raise CheckError("Talaria reference inventory drift")
    expected = {
        "PR91-durable-host-update-recovery": {
            "branch": "codex/durable-host-update-recovery",
            "commit": "cc3322f674ac388c55a9d2694efaaf7e941a1666",
            "parent": "a8463632e409620d471cfd40d25b2197015ae00d",
            "state": "implemented-excluded",
        },
        "PR94-model-discount-presentation": {
            "branch": "codex/model-contract-copy",
            "commit": "5cb68d2dd38539b2f5de789e7be95a545437ca22",
            "parent": "27a12f11c3825cc8ada4860b60e298acdcc4fa37 ff0ea1a6e91c3af0996f406dac0acf9f607cc166",
            "state": "merged-to-parent-not-main-uncertified",
        },
    }
    seen: set[str] = set()
    for row in refs:
        if not isinstance(row, dict) or set(row) != {
            "id", "branch", "commit", "parent", "state", "upstreamCommits", "note",
        }:
            raise CheckError("Talaria reference fields drift")
        identifier = str(row["id"])
        if identifier in seen or identifier not in expected:
            raise CheckError("unknown Talaria reference")
        seen.add(identifier)
        for field, value in expected[identifier].items():
            if row[field] != value:
                raise CheckError(f"Talaria reference drift: {identifier}")
        commits = row["upstreamCommits"]
        if not isinstance(commits, list) or not commits or any(not SHA40.fullmatch(str(value)) for value in commits):
            raise CheckError(f"Talaria reference upstream commits invalid: {identifier}")
        if not isinstance(row["note"], str) or not row["note"].strip():
            raise CheckError(f"Talaria reference note missing: {identifier}")
    if seen != set(expected):
        raise CheckError("Talaria reference set drift")


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "scopeRules", "scopeCorrection",
        "scopedCommitCount", "scopedMergeCount", "entryCount", "entriesFile", "rawHistoryPathCount",
        "rawHistoryPathSha256", "historyPathCount", "historyPathSha256", "clusterDefinitions",
        "clusterCounts", "classificationCounts", "dispositionCounts", "talariaStatusCounts", "finalNetFiles",
        "predecessorLedgers", "predecessorCounts", "talariaReferences", "sourceAssertions",
        "sourceAbsenceAssertions",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    if metadata["repository"] != EXPECTED_REPOSITORY or metadata["baseCommit"] != EXPECTED_BASE or metadata["targetCommit"] != EXPECTED_TARGET:
        raise CheckError("exact upstream authority drift")
    if metadata["scopeRules"] != SCOPE_RULES:
        raise CheckError("scope rules drift")
    correction = metadata["scopeCorrection"]
    if correction != {
        "rawEveryParentPathCount": 126,
        "productionPathCount": 124,
        "generatedExcludedPaths": SCOPE_RULES["excludeExact"][1:],
    }:
        raise CheckError("scope correction drift")
    if metadata["scopedCommitCount"] != 167 or metadata["scopedMergeCount"] != 30 or metadata["entryCount"] != 167:
        raise CheckError("exact every-parent inventory count drift")
    if metadata["rawHistoryPathCount"] != 126 or metadata["historyPathCount"] != 124:
        raise CheckError("history path count drift")
    for key in ("rawHistoryPathSha256", "historyPathSha256"):
        if not SHA64.fullmatch(str(metadata[key])):
            raise CheckError(f"invalid {key}")
    if metadata["entriesFile"] != "hermes-cli-delta-40643cba-057dcdf.tsv":
        raise CheckError("entries file drift")

    clusters = metadata["clusterDefinitions"]
    if not isinstance(clusters, dict) or not clusters:
        raise CheckError("cluster definitions missing")
    for identifier, row in clusters.items():
        if not identifier or not isinstance(row, dict) or set(row) != {
            "classification", "disposition", "talariaStatus", "contract", "evidence", "required",
        }:
            raise CheckError(f"invalid cluster definition: {identifier}")
        if row["classification"] not in CLASSIFICATIONS or row["disposition"] not in DISPOSITIONS or row["talariaStatus"] not in TALARIA_STATUSES:
            raise CheckError(f"invalid cluster semantics: {identifier}")
        if any(not isinstance(row[field], str) or not row[field].strip() for field in ("contract", "evidence", "required")):
            raise CheckError(f"empty cluster evidence: {identifier}")

    entries = _read_tsv(metadata_path.parent / _safe_path(metadata["entriesFile"]), FIELDS)
    if len(entries) != metadata["entryCount"]:
        raise CheckError("entry count mismatch")
    seen: set[str] = set()
    for row in entries:
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen:
            raise CheckError(f"invalid or duplicate commit: {commit}")
        seen.add(commit)
        paths = row["paths"].split(";")
        if not paths or paths != sorted(set(paths)) or any(not _production_scoped(path) for path in paths):
            raise CheckError(f"invalid paths for {commit}")
        cluster = row["cluster"]
        if cluster not in clusters:
            raise CheckError(f"unknown cluster for {commit}")
        definition = clusters[cluster]
        for field in ("classification", "disposition", "talariaStatus"):
            if row[field] != definition[field]:
                raise CheckError(f"cluster semantics drift for {commit}")
        predecessor = row["predecessors"]
        if predecessor != "none" and not re.fullmatch(r"(?:authority|client-wire|core-runtime):[^;]+", predecessor):
            raise CheckError(f"invalid predecessor reference for {commit}")
    _validate_counter(metadata["clusterCounts"], Counter(row["cluster"] for row in entries), "clusterCounts")
    _validate_counter(metadata["classificationCounts"], Counter(row["classification"] for row in entries), "classificationCounts")
    _validate_counter(metadata["dispositionCounts"], Counter(row["disposition"] for row in entries), "dispositionCounts")
    _validate_counter(metadata["talariaStatusCounts"], Counter(row["talariaStatus"] for row in entries), "talariaStatusCounts")

    net_files = metadata["finalNetFiles"]
    if not isinstance(net_files, list) or not net_files:
        raise CheckError("final net manifest missing")
    net_paths: list[str] = []
    for row in net_files:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("final net manifest fields drift")
        path = _safe_path(row["path"])
        if not _production_scoped(path):
            raise CheckError(f"non-production final net path: {path}")
        net_paths.append(path)
        if any(value != "absent" and not SHA64.fullmatch(str(value)) for value in (row["baseSha256"], row["targetSha256"])):
            raise CheckError(f"invalid final net hash: {path}")
    if net_paths != sorted(set(net_paths)):
        raise CheckError("final net paths must be sorted and unique")

    _validate_reference_metadata(metadata)
    counts = metadata["predecessorCounts"]
    if not isinstance(counts, dict) or set(counts) != set(PREDECESSOR_LEDGERS) or any(not isinstance(value, int) or value < 0 for value in counts.values()):
        raise CheckError("predecessor count manifest drift")
    assertions = metadata["sourceAssertions"]
    if not isinstance(assertions, list) or len(assertions) < 5:
        raise CheckError("source assertions missing")
    for row in assertions:
        if not isinstance(row, dict) or set(row) != {"path", "contains", "description"}:
            raise CheckError("source assertion fields drift")
        _safe_path(row["path"])
        if not isinstance(row["contains"], str) or not row["contains"] or not isinstance(row["description"], str) or not row["description"]:
            raise CheckError("source assertion value drift")
    absence_assertions = metadata["sourceAbsenceAssertions"]
    if not isinstance(absence_assertions, list) or len(absence_assertions) < 2:
        raise CheckError("source absence assertions missing")
    for row in absence_assertions:
        if not isinstance(row, dict) or set(row) != {"path", "notContains", "description"}:
            raise CheckError("source absence assertion fields drift")
        _safe_path(row["path"])
        if not isinstance(row["notContains"], str) or not row["notContains"] or not isinstance(row["description"], str) or not row["description"]:
            raise CheckError("source absence assertion value drift")
    return metadata, entries


def _pinned_predecessor_rows(metadata: dict[str, Any]) -> dict[str, dict[str, dict[str, str]]]:
    result: dict[str, dict[str, dict[str, str]]] = {}
    for ledger, expected in PREDECESSOR_LEDGERS.items():
        pin = metadata["predecessorLedgers"][ledger]
        _local_git("cat-file", "-e", f"{pin['head']}^{{commit}}")
        text = _local_git("show", f"{pin['head']}:{pin['entriesFile']}")
        rows = _read_tsv_text(text, expected["fields"], f"{ledger} predecessor ledger")
        result[ledger] = {row["commit"]: row for row in rows}
    return result


def _verify_talaria_references(metadata: dict[str, Any]) -> None:
    for row in metadata["talariaReferences"]:
        _local_git("cat-file", "-e", f"{row['commit']}^{{commit}}")
        parent = _local_git("show", "-s", "--format=%P", row["commit"])
        if parent != row["parent"]:
            raise CheckError(f"Talaria reference parent drift: {row['id']}")


def _verify_source_assertions(metadata: dict[str, Any], checkout: Path) -> None:
    target = str(metadata["targetCommit"])
    for row in metadata["sourceAssertions"]:
        source = _git_bytes(checkout, "show", f"{target}:{row['path']}").decode(errors="replace")
        if row["contains"] not in source:
            raise CheckError(f"source assertion drift: {row['path']}")
    for row in metadata["sourceAbsenceAssertions"]:
        source = _git_bytes(checkout, "show", f"{target}:{row['path']}").decode(errors="replace")
        if row["notContains"] in source:
            raise CheckError(f"source absence assertion drift: {row['path']}")


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path) -> None:
    base = str(metadata["baseCommit"])
    target = str(metadata["targetCommit"])
    _git(checkout, "cat-file", "-e", f"{base}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{target}^{{commit}}")
    commits, paths_by_commit, raw_paths = _inventory(metadata, checkout)
    production_paths = sorted(set().union(*paths_by_commit.values()))
    if len(commits) != metadata["scopedCommitCount"] or sum(len(_git(checkout, "show", "-s", "--format=%P", commit).split()) > 1 for commit in commits) != metadata["scopedMergeCount"]:
        raise CheckError("every-parent scoped commit or merge count drift")
    if len(raw_paths) != metadata["rawHistoryPathCount"] or _hash_paths(sorted(raw_paths)) != metadata["rawHistoryPathSha256"]:
        raise CheckError("raw history path inventory drift")
    if len(production_paths) != metadata["historyPathCount"] or _hash_paths(production_paths) != metadata["historyPathSha256"]:
        raise CheckError("production history path inventory drift")

    entry_map = {row["commit"]: row for row in entries}
    if list(entry_map) != commits:
        raise CheckError("commit order or coverage drift")
    predecessors = _pinned_predecessor_rows(metadata)
    predecessor_counts: Counter[str] = Counter()
    for commit in commits:
        row = entry_map[commit]
        if set(row["paths"].split(";")) != paths_by_commit[commit]:
            raise CheckError(f"merge-parent path union drift for {commit}")
        matches = [ledger for ledger, rows in predecessors.items() if commit in rows]
        if len(matches) > 1:
            raise CheckError(f"ambiguous predecessor evidence: {commit}")
        expected = "none"
        if matches:
            ledger = matches[0]
            expected = f"{ledger}:{predecessors[ledger][commit]['cluster']}"
            predecessor_counts[ledger] += 1
        if row["predecessors"] != expected:
            raise CheckError(f"predecessor cross-reference drift for {commit}")
    if dict(predecessor_counts) != metadata["predecessorCounts"]:
        raise CheckError("predecessor count drift")

    net_paths = sorted(path for path in _git(checkout, "diff", "--name-only", f"{base}..{target}", "--", "hermes_cli").splitlines() if _production_scoped(path))
    net_rows = metadata["finalNetFiles"]
    if net_paths != [row["path"] for row in net_rows]:
        raise CheckError("final net path drift")
    for row in net_rows:
        for endpoint, field in ((base, "baseSha256"), (target, "targetSha256")):
            if _blob_hash(checkout, endpoint, row["path"]) != row[field]:
                raise CheckError(f"{field} drift for {row['path']}")
    _verify_source_assertions(metadata, checkout)
    _verify_talaria_references(metadata)


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
        f"{metadata['historyPathCount']} production paths, "
        f"{sum(metadata['predecessorCounts'].values())} predecessor references"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
