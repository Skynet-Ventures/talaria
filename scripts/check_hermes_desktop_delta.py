#!/usr/bin/env python3
"""Validate the bounded Hermes Desktop/Electron delta ledger.

The ledger is deliberately an every-parent Git inventory, not a first-parent
log.  It pins the upstream range, the two renderer roots, predecessor-ledger
heads, endpoint trees/blobs, and the small set of auditable mobile outcomes.
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
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_METADATA = ROOT / "parity" / "hermes-desktop-delta-40643cba-057dcdf.json"
EXPECTED_REPOSITORY = "https://github.com/nousresearch/hermes-agent.git"
EXPECTED_BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
EXPECTED_TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
EXACT_SCOPE_ROOTS = ["apps/desktop/src", "apps/desktop/electron"]
EXPECTED_SCOPED_COMMITS = 241
EXPECTED_MERGE_COMMITS = 34
EXPECTED_HISTORY_PATHS = 1072
EXPECTED_FINAL_NET_PATHS = 345
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")

FIELDS = [
    "commit", "paths", "parentCount", "cluster", "classification", "disposition",
    "talariaSlice", "predecessors", "contract", "evidence", "required",
]
AUTHORITY_FIELDS = [
    "commit", "paths", "cluster", "disposition", "contract", "evidence", "required",
]
CLIENT_WIRE_FIELDS = [
    "commit", "paths", "cluster", "disposition", "impact", "contract", "evidence", "required",
]
CORE_FIELDS = [
    "commit", "paths", "cluster", "classification", "disposition",
    "talariaSlice", "contract", "evidence", "required",
]

PINNED_LEDGER_HEADS: dict[str, dict[str, object]] = {
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
    "core-runtime": {
        "ledgerFile": "parity/hermes-core-runtime-delta-40643cba-057dcdf.tsv",
        "metadataFile": "parity/hermes-core-runtime-delta-40643cba-057dcdf.json",
        "head": "7e46a9ab4e68f4f74ecc68fe2222798883a66091",
        "fields": CORE_FIELDS,
    },
}

OPEN_SLICE_HEADS = {
    "source-qualified-push-presentation": (
        "codex/source-qualified-push-presentation",
        "1b50d7969810c33582caaad5273b8e83520ad54d",
    ),
    "compact-bot-profile": (
        "codex/current-hermes-compact-bot-profile",
        "44829a1b5193b363f1ab747a825487bff1d7bf75",
    ),
    "durable-composer-queue": (
        "codex/current-hermes-durable-composer-queue-v2",
        "ce5851f26bfc2853a37a18aac125d875a6316b34",
    ),
    "durable-room-composer-drafts": (
        "codex/durable-room-composer-drafts",
        "1d88002454ec70c06bc3aa60fa44248a1b848cfd",
    ),
    "durable-room-member-holds": (
        "codex/durable-room-member-holds",
        "d27e7839aeb94fcf79438513b3f31da7306e1dbf",
    ),
    "stale-bot-session-reconciliation": (
        "codex/stale-bot-session-reconciliation",
        "23bf4e618a4b772bc2b7b6c4dc30f456d8ff14d0",
    ),
    "attachment-picker-polish": (
        "codex/attachment-picker-polish",
        "9f26348d576004d40da8b3f03c2cb6c93b4333c3",
    ),
    "artifact-remote-body": (
        "codex/artifact-remote-body",
        "9591d177ec271b06a017c879b3b643d6c228c1a1",
    ),
    "rich-transcript-hydration": (
        "codex/rich-transcript-hydration",
        "d5bad705f1c19d716eea4abb8de1ba4206659dde",
    ),
    "rich-transcript-structured-output": (
        "codex/rich-transcript-structured-output",
        "fdee839fdc1fda8a4a8233ff5e459795d09752b0",
    ),
    "rich-transcript-diff-renderer": (
        "codex/rich-transcript-diff-renderer",
        "f0d5aa814c3c6411419dfef2e00d9ff711d78a59",
    ),
    "durable-host-update-recovery": (
        "codex/durable-host-update-recovery",
        "cc3322f674ac388c55a9d2694efaaf7e941a1666",
    ),
    "live-activity-policy": (
        "codex/current-hermes-live-activity-policy",
        "2b4dcd47df49e32e1d39c95a16ab9520033590bd",
    ),
}

PR94 = {
    "id": "pr94-model-discount-presentation",
    "branch": "codex/model-discount-presentation",
    "head": "ff0ea1a6e91c3af0996f406dac0acf9f607cc166",
    "state": "implemented-on-open-branch-not-merged-or-device-certified",
    "upstreamCommits": [
        "1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4",
        "bd93a5f3160dc84d1891e27b49bffeb88483d8f0",
    ],
    "talariaFiles": [
        "Packages/Talaria/Sources/TalariaUI/GatewayClient+Models.swift",
        "Packages/Talaria/Sources/TalariaUI/Screens/ModelEffortSheet.swift",
        "Packages/Talaria/Sources/TalariaUI/Screens/Settings/ModelSettings.swift",
        "Packages/Talaria/Tests/TalariaUITests/ModelManagementContractTests.swift",
    ],
}

CLASSIFICATIONS = {
    "source-qualified-mobile-contract",
    "portable-model-presentation",
    "desktop-host-runtime",
    "desktop-only",
    "existing-backlog",
    "test-fixture-or-build-only",
    "merge-parent-integration",
    "desktop-renderer-presentation",
}
DISPOSITIONS = {
    "cross-referenced-predecessor",
    "covered-by-open-slice",
    "implemented-by-pr94-not-merged-or-device-certified",
    "desktop-only",
    "existing-backlog",
    "test-fixture-or-build-only",
    "merge-parent-integration",
    "audited-no-new-mobile-slice",
}

MODEL_PR94_COMMITS = set(PR94["upstreamCommits"])
EXISTING_BACKLOG_COMMITS = {
    "0a171fffef0e50aef4b26718c484431f4247a4bb",  # goal-chip text parser
}
DESKTOP_ONLY_COMMITS = {
    # HUD/windowing, Electron-only compositor behavior, and desktop-local relay.
    "3c19644419712d187b636e0bcb66ae993e7249b1",
    "6e64e6b9c697460ef303a90fc9444e0bb34788fc",
    "f33b260afa13d89063d452f36eae44b6b403b340",
    "67a5d7bcf0b3b3fbf7b3180536dc6295bc5f6813",
    "433f518cad08c473a7c14f893e36fee253ab19e8",
    "11f3ebe2302b70c14b3303257002113965307bcb",
    "fab0de1c5b06113e6b5827766c155680eceafb0b",
    "b595fcd5e16425a78b168881d9401b9d07e8e187",
    "d467da910077be76d72ea2c4f17e94e56fbffa23",
    "81baae6bc3af215eb596380ed57be92ee9996fda",
    "3f590e68df3798f436128c444fb0ae02f744e78c",
    "db6c282c914cbc2ebac8e304c407dee8ad924acf",
    "b484933005ba966a1aa93c69581cae28e241cd6c",
    "765e3a2f8afb1b2653043b681e7d647d6df85d1a",
    "73dcd75afe1e78562271e59cba14d39ee387865e",
    "beb848358d365b8742b9dcee069f07b34b944770",
    "10f0d2278bf7ea7dd005e5c8b1b9dc47d108a1ec",
    "1ad4733343af1ff48733b992d9aa6e1abf59a187",
    "9c829f965dcd4b2ee536dbafcf555f58b0d110b5",
    "bb63e0c4c7469f80115a9cf982ed224d8ffe49d0",
    "b614e2656b70726868f556d6ab4e1419d68eea08",
}

OPEN_SLICE_BY_COMMIT = {
    "4f64807f5da1efe765ff90e8774e3d09d4487c81": "durable-composer-queue",
    "534719259cacc5897ac30f93cce70dc6f1ec8a06": "durable-composer-queue",
    "11fd82cf20d7c2356197e95ec79f457b06d28e12": "durable-composer-queue",
    "18e941ac2fdca2185209e3cb80baf57957cd269a": "durable-composer-queue",
    "77dd0699465815d6160548becbf92b267c1b505a": "durable-composer-queue",
    "17f8e24c81674eee97450b44dab41929a49b9c69": "durable-composer-queue",
    "5ef205d8558bc8f9a827fd80a2840614d1a7886c": "durable-composer-queue",
    "e8d5660bae1db35182a35e03e564be0b584ebedc": "durable-composer-queue",
    "febed060ab44bcfa35388ba45b88cb6ac78fbe21": "durable-composer-queue",
    "72f6127b98f20a170e9adb2c90c3680144f7d1d5": "durable-composer-queue",
    "319e77eea44171c3c18f3cc1b57ea8af3c69b8c5": "durable-composer-queue",
    "d12bc0c4d9d502ed921d6d086f7f7b42ebbd5e63": "durable-composer-queue",
    "b90289b046613fe9b3c3c446f796de451ba7fdbc": "durable-host-update-recovery",
    "6eb77df1aa841a482334e1ed8341ef9964d0f497": "attachment-picker-polish",
    "0b62c27bf13b3c870d33b8b726ae0b7b48313931": "artifact-remote-body",
    "30150fd08261a248968fb86460b7a9940e48640a": "artifact-remote-body",
    "9abeb89a497feda49a2e61ea892077429d8b9325": "artifact-remote-body",
    "9f8dca34dc2adb289153edfc11cc47e0ff583f24": "rich-transcript-structured-output",
    "40f3e58f6de96b9151170c57a0e4918d42c338d2": "rich-transcript-structured-output",
}

SOURCE_ASSERTIONS = [
    {
        "path": "apps/desktop/src/lib/model-search-text.ts",
        "contains": "'x-preview-f-free': ['ox-alpha', 'ox']",
        "description": "Desktop preserves the opaque wire id and adds Ox Alpha aliases only to search text.",
    },
    {
        "path": "apps/desktop/src/components/model-picker.tsx",
        "contains": "price.discount_percent",
        "description": "Desktop renders provider-supplied discount metadata in ModelPrice rather than changing catalog identity.",
    },
    {
        "path": "apps/desktop/src/store/goals.ts",
        "contains": "DONE_LINGER_MS",
        "description": "The range fixes a desktop-local goal-chip retirement timer; it is not a new typed mobile contract.",
    },
    {
        "path": "apps/desktop/src/store/updates.ts",
        "contains": "receiptProvesOutcome",
        "description": "Update receipts/reconnect are desktop orchestration evidence and remain under the active host-recovery slice.",
    },
]


class CheckError(RuntimeError):
    pass


def _git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {str(detail).strip()}") from error
    return result.stdout.strip()


def _git_bytes(checkout: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, timeout=120,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise CheckError(f"git {' '.join(arguments)} failed: {str(detail).strip()}") from error
    return result.stdout


def _safe_path(raw: object) -> str:
    value = str(raw)
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts:
        raise CheckError(f"unsafe path: {value}")
    return value


def _is_scoped_path(path: str) -> bool:
    return any(path == root or path.startswith(f"{root}/") for root in EXACT_SCOPE_ROOTS)


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


def _path_category(path: str) -> str:
    lowered = path.lower()
    name = Path(lowered).name
    if (
        "/tests/" in lowered
        or "/fixtures/" in lowered
        or "/fixture/" in lowered
        or "/src/test/" in lowered
        or ".test." in name
        or ".spec." in name
        or name.endswith("-fixture.js")
    ):
        return "test_fixture"
    if "/i18n/" in lowered:
        return "locale"
    if name.endswith(".css"):
        return "style"
    if name in {"package.json", "tsconfig.json"} or name.endswith(".d.ts"):
        return "build_type"
    return "production"


def _all_auxiliary(paths: Iterable[str]) -> bool:
    values = list(paths)
    return bool(values) and all(_path_category(path) != "production" for path in values)


def _cluster(paths: set[str], parent_count: int) -> str:
    joined = "\n".join(paths)
    if parent_count > 1:
        return "D10-merge-parent-integration"
    if _all_auxiliary(paths):
        return "D09-test-fixture-localization-or-build"
    if "model-" in joined or "/settings/" in joined or "model-picker" in joined:
        return "D06-model-settings-and-provider-surface"
    if "/plugins/hermes-bots/" in joined:
        return "D02-bot-rooms-roster-and-identity"
    if "native-notifications" in joined or "profile-" in joined or "/profile" in joined:
        return "D01-notification-identity-and-source-routing"
    if any(token in joined for token in (
        "gateway", "session-states", "session-request-router", "updates.ts", "inflight-turn",
    )):
        return "D03-reconnect-queue-and-update-lifecycle"
    if any(token in joined for token in (
        "attachments", "desktop-fs", "project-tree", "artifacts", "gateway-file-download",
        "git-worktree", "desktop-git", "media.",
    )):
        return "D05-files-media-artifacts-and-worktrees"
    if any(token in joined for token in (
        "chat-messages", "assistant-ui", "/tool/", "transcript", "message-stream",
    )):
        return "D04-transcript-tool-and-turn-rendering"
    if "/electron/" in joined or "/hud/" in joined or "pane-shell" in joined:
        return "D07-desktop-shell-windowing-and-motion"
    return "D08-renderer-presentation-and-settings-backlog"


def _is_electron_host_only(paths: set[str]) -> bool:
    production = [path for path in paths if _path_category(path) == "production"]
    return bool(production) and all(path.startswith("apps/desktop/electron/") for path in production)


def _policy(
    commit: str,
    paths: set[str],
    parent_count: int,
    predecessors: tuple[str, ...],
) -> dict[str, str]:
    cluster = _cluster(paths, parent_count)
    predecessor_text = ";".join(predecessors) if predecessors else "none"
    if commit in MODEL_PR94_COMMITS:
        return {
            "cluster": "D06-model-settings-and-provider-surface",
            "classification": "portable-model-presentation",
            "disposition": "implemented-by-pr94-not-merged-or-device-certified",
            "talariaSlice": PR94["id"],
            "predecessors": predecessor_text,
            "contract": "Model search aliases and bounded provider discount metadata are local presentation only; wire IDs, catalog identity, routing, and provider ownership remain gateway-owned.",
            "evidence": "The exact Desktop source path is retained above; PR94 pins the matching Talaria alias and bounded-sale presentation implementation.",
            "required": "Run the PR94 model-contract tests plus device/live-gateway certification before claiming merged or certified coverage.",
        }
    if commit in EXISTING_BACKLOG_COMMITS:
        return {
            "cluster": "D08-renderer-presentation-and-settings-backlog",
            "classification": "existing-backlog",
            "disposition": "existing-backlog",
            "talariaSlice": "none",
            "predecessors": predecessor_text,
            "contract": "The goal-chip text parser and linger timer are a pre-existing broad composer-status concern, not a typed upstream mobile contract introduced by this delta.",
            "evidence": "apps/desktop/src/store/goals.ts parses slash.exec prose and retains a local DONE_LINGER_MS timer.",
            "required": "Keep this in the existing composer-status backlog; do not create a narrow wire slice from a desktop prose parser.",
        }
    if commit in DESKTOP_ONLY_COMMITS or _is_electron_host_only(paths):
        return {
            "cluster": "D07-desktop-shell-windowing-and-motion",
            "classification": "desktop-only" if commit in DESKTOP_ONLY_COMMITS else "desktop-host-runtime",
            "disposition": "desktop-only",
            "talariaSlice": "none",
            "predecessors": predecessor_text,
            "contract": "Electron windowing, local relay drain, client-direct credential access, compositor animation, and desktop filesystem/process behavior do not transfer to an iOS app runtime.",
            "evidence": "The exact Electron/renderer paths are retained above and the endpoint hashes prove the audited Desktop implementation.",
            "required": "Do not port host ownership or desktop shell mechanics; use the separately audited mobile policy/notification surfaces where an iOS analogue exists.",
        }
    if parent_count > 1:
        return {
            "cluster": "D10-merge-parent-integration",
            "classification": "merge-parent-integration",
            "disposition": "merge-parent-integration",
            "talariaSlice": "none",
            "predecessors": predecessor_text,
            "contract": "This merge is inventory evidence: all parent-side Desktop path changes are retained without inventing a separate mobile feature.",
            "evidence": "The checker replays and unions every parent diff for this exact merge commit.",
            "required": "Validate constituent source-qualified slices; no standalone mobile implementation follows from a merge node.",
        }
    if _all_auxiliary(paths):
        return {
            "cluster": "D09-test-fixture-localization-or-build",
            "classification": "test-fixture-or-build-only",
            "disposition": "test-fixture-or-build-only",
            "talariaSlice": "none",
            "predecessors": predecessor_text,
            "contract": "The scoped diff is test, fixture, locale, style, or build/type support and carries no standalone mobile runtime contract.",
            "evidence": "Path-category classification is deterministic and every path is recorded above.",
            "required": "Retain upstream regression evidence; no Talaria product slice is implied.",
        }
    if predecessors:
        return {
            "cluster": cluster,
            "classification": "source-qualified-mobile-contract",
            "disposition": "cross-referenced-predecessor",
            "talariaSlice": "none",
            "predecessors": predecessor_text,
            "contract": "The mobile-relevant authority, wire, or core-runtime behavior is already owned by the exact predecessor ledger(s) named in this row.",
            "evidence": "The checker reads each predecessor ledger from its pinned commit and requires the exact same upstream commit intersection.",
            "required": "Use the predecessor ledger's narrow dependency and verification evidence; do not duplicate its mobile work here.",
        }
    slice_id = OPEN_SLICE_BY_COMMIT.get(commit)
    if slice_id:
        return {
            "cluster": cluster,
            "classification": "source-qualified-mobile-contract",
            "disposition": "covered-by-open-slice",
            "talariaSlice": slice_id,
            "predecessors": predecessor_text,
            "contract": "The renderer change has a source-qualified mobile consequence already isolated in the named open Talaria slice.",
            "evidence": "The checker pins the open slice head and retains the exact upstream source-path evidence in this row.",
            "required": "Finish that slice's local and device/gateway verification; this ledger does not claim it is merged or certified.",
        }
    return {
        "cluster": cluster,
        "classification": "desktop-renderer-presentation",
        "disposition": "audited-no-new-mobile-slice",
        "talariaSlice": "none",
        "predecessors": predecessor_text,
        "contract": "This Desktop renderer change was reviewed against the current mobile/parity stack and introduces no additional narrow, source-qualified mobile runtime slice beyond existing backlog or predecessor coverage.",
        "evidence": "The exact every-parent source paths are retained in this row; the documentation records representative symbols and the mobile disposition.",
        "required": "Keep it as Desktop parity context; open a mobile slice only when a concrete mobile interaction or typed gateway contract is separately identified.",
    }


def _scoped_inventory(checkout: Path) -> tuple[list[str], dict[str, int], dict[str, set[str]]]:
    candidates = _git(checkout, "rev-list", "--reverse", f"{EXPECTED_BASE}..{EXPECTED_TARGET}").splitlines()
    commits: list[str] = []
    parent_counts: dict[str, int] = {}
    paths_by_commit: dict[str, set[str]] = {}
    for commit in candidates:
        parents = _git(checkout, "show", "-s", "--format=%P", commit).split()
        changed: set[str] = set()
        for parent in parents:
            changed.update(_git(checkout, "diff", "--name-only", parent, commit, "--", *EXACT_SCOPE_ROOTS).splitlines())
        changed = {path for path in changed if _is_scoped_path(path)}
        if changed:
            commits.append(commit)
            parent_counts[commit] = len(parents)
            paths_by_commit[commit] = changed
    return commits, parent_counts, paths_by_commit


def _blob_hash(checkout: Path, commit: str, path: str) -> str:
    present = _git(checkout, "ls-tree", "--name-only", commit, "--", path)
    if present != path:
        return "absent"
    return hashlib.sha256(_git_bytes(checkout, "show", f"{commit}:{path}")).hexdigest()


def _tree_hash(checkout: Path, commit: str, path: str) -> str:
    return _git(checkout, "rev-parse", f"{commit}:{path}")


def _pinned_ledger_rows() -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for ledger, config in PINNED_LEDGER_HEADS.items():
        head = str(config["head"])
        ledger_file = str(config["ledgerFile"])
        _git(ROOT, "cat-file", "-e", f"{head}^{{commit}}")
        rows = _read_tsv_text(
            _git(ROOT, "show", f"{head}:{ledger_file}"),
            list(config["fields"]),
            f"{ledger} ledger at {head}",
        )
        values = {row["commit"]: row["cluster"] for row in rows}
        if ledger == "core-runtime":
            metadata_file = str(config["metadataFile"])
            core_metadata = json.loads(_git(ROOT, "show", f"{head}:{metadata_file}"))
            refs = core_metadata.get("crossReferences")
            if not isinstance(refs, list):
                raise CheckError("core-runtime predecessor cross-reference metadata is missing")
            for row in refs:
                commit = row.get("commit")
                cluster = row.get("ledgerCluster")
                if not isinstance(commit, str) or not isinstance(cluster, str) or commit in values:
                    raise CheckError("core-runtime predecessor cross-reference drift")
                values[commit] = cluster
        result[ledger] = values
    return result


def _predecessors_for(commits: Iterable[str], ledgers: dict[str, dict[str, str]]) -> dict[str, tuple[str, ...]]:
    return {
        commit: tuple(ledger for ledger in PINNED_LEDGER_HEADS if commit in ledgers[ledger])
        for commit in commits
    }


def _inventory_digest(commits: list[str], parent_counts: dict[str, int], paths_by_commit: dict[str, set[str]]) -> str:
    payload = "\n".join(
        f"{commit}\t{parent_counts[commit]}\t{';'.join(sorted(paths_by_commit[commit]))}"
        for commit in commits
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def _counter_dict(values: Iterable[str]) -> dict[str, int]:
    return dict(sorted(Counter(values).items()))


def _build_entries(checkout: Path) -> tuple[list[dict[str, str]], list[str], dict[str, int], dict[str, set[str]], dict[str, tuple[str, ...]]]:
    commits, parent_counts, paths_by_commit = _scoped_inventory(checkout)
    predecessors = _predecessors_for(commits, _pinned_ledger_rows())
    entries: list[dict[str, str]] = []
    for commit in commits:
        policy = _policy(commit, paths_by_commit[commit], parent_counts[commit], predecessors[commit])
        entries.append({
            "commit": commit,
            "paths": ";".join(sorted(paths_by_commit[commit])),
            "parentCount": str(parent_counts[commit]),
            **policy,
        })
    return entries, commits, parent_counts, paths_by_commit, predecessors


def _build_metadata(checkout: Path) -> dict[str, Any]:
    entries, commits, parent_counts, paths_by_commit, predecessors = _build_entries(checkout)
    history_paths = sorted(set().union(*paths_by_commit.values()))
    final_paths = _git(
        checkout, "diff", "--name-only", f"{EXPECTED_BASE}..{EXPECTED_TARGET}", "--", *EXACT_SCOPE_ROOTS
    ).splitlines()
    final_paths = sorted(path for path in final_paths if _is_scoped_path(path))
    final_net = [
        {
            "path": path,
            "baseSha256": _blob_hash(checkout, EXPECTED_BASE, path),
            "targetSha256": _blob_hash(checkout, EXPECTED_TARGET, path),
        }
        for path in final_paths
    ]
    predecessor_counts = {
        ledger: sum(ledger in predecessors[commit] for commit in commits)
        for ledger in PINNED_LEDGER_HEADS
    }
    combination_counts = _counter_dict(
        ";".join(predecessors[commit])
        for commit in commits if predecessors[commit]
    )
    return {
        "schemaVersion": 1,
        "repository": EXPECTED_REPOSITORY,
        "baseCommit": EXPECTED_BASE,
        "targetCommit": EXPECTED_TARGET,
        "scopeRoots": EXACT_SCOPE_ROOTS,
        "methodology": "Every reachable commit is checked against every parent with git diff --name-only <parent> <commit> -- apps/desktop/src apps/desktop/electron; merge path sets are the union. The final-net tree is independently hashed at both endpoints.",
        "scopedCommitCount": len(commits),
        "mergeCommitCount": sum(parent_counts[commit] > 1 for commit in commits),
        "entryCount": len(entries),
        "entriesFile": "hermes-desktop-delta-40643cba-057dcdf.tsv",
        "historyPathUnion": history_paths,
        "historyPathKinds": [
            {"path": path, "kind": _path_category(path)} for path in history_paths
        ],
        "historyPathCategoryCounts": _counter_dict(_path_category(path) for path in history_paths),
        "everyParentInventorySha256": _inventory_digest(commits, parent_counts, paths_by_commit),
        "finalNetFiles": final_net,
        "finalNetCategoryCounts": _counter_dict(_path_category(path) for path in final_paths),
        "treeHashes": {
            root: {
                "base": _tree_hash(checkout, EXPECTED_BASE, root),
                "target": _tree_hash(checkout, EXPECTED_TARGET, root),
            }
            for root in EXACT_SCOPE_ROOTS
        },
        "clusterCounts": _counter_dict(row["cluster"] for row in entries),
        "classificationCounts": _counter_dict(row["classification"] for row in entries),
        "dispositionCounts": _counter_dict(row["disposition"] for row in entries),
        "crossReferenceHeads": {
            ledger: {
                "ledgerFile": str(config["ledgerFile"]),
                "head": str(config["head"]),
            }
            for ledger, config in PINNED_LEDGER_HEADS.items()
        },
        "crossReferenceCounts": predecessor_counts,
        "crossReferenceUnionCount": sum(bool(predecessors[commit]) for commit in commits),
        "predecessorCombinationCounts": combination_counts,
        "openTalariaSlices": [
            {"id": slice_id, "branch": branch, "head": head}
            for slice_id, (branch, head) in OPEN_SLICE_HEADS.items()
        ],
        "pr94": PR94,
        "sourceAssertions": SOURCE_ASSERTIONS,
    }


def _validate_counter(value: object, expected: Counter[str], name: str) -> None:
    if value != dict(sorted(expected.items())):
        raise CheckError(f"{name} drift")


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "scopeRoots", "methodology",
        "scopedCommitCount", "mergeCommitCount", "entryCount", "entriesFile", "historyPathUnion", "historyPathKinds",
        "historyPathCategoryCounts", "everyParentInventorySha256", "finalNetFiles", "finalNetCategoryCounts",
        "treeHashes", "clusterCounts", "classificationCounts", "dispositionCounts", "crossReferenceHeads",
        "crossReferenceCounts", "crossReferenceUnionCount", "predecessorCombinationCounts", "openTalariaSlices",
        "pr94", "sourceAssertions",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    if metadata["repository"] != EXPECTED_REPOSITORY:
        raise CheckError("repository must retain pinned Hermes upstream")
    if metadata["baseCommit"] != EXPECTED_BASE or metadata["targetCommit"] != EXPECTED_TARGET:
        raise CheckError("upstream range must retain exact audited endpoints")
    if metadata["scopeRoots"] != EXACT_SCOPE_ROOTS:
        raise CheckError("scopeRoots must retain the exact Desktop/Electron roots")
    if not isinstance(metadata["methodology"], str) or "every parent" not in metadata["methodology"]:
        raise CheckError("methodology must retain every-parent proof")
    if (
        metadata["scopedCommitCount"] != EXPECTED_SCOPED_COMMITS
        or metadata["mergeCommitCount"] != EXPECTED_MERGE_COMMITS
        or metadata["entryCount"] != EXPECTED_SCOPED_COMMITS
    ):
        raise CheckError("bounded inventory must remain 241 scoped / 34 merge / 241 ledger rows")
    history_paths = metadata["historyPathUnion"]
    if (
        not isinstance(history_paths, list)
        or len(history_paths) != EXPECTED_HISTORY_PATHS
        or history_paths != sorted(set(history_paths))
        or not all(_is_scoped_path(_safe_path(path)) for path in history_paths)
    ):
        raise CheckError("history path manifest drift")
    if not SHA64.fullmatch(str(metadata["everyParentInventorySha256"])):
        raise CheckError("every-parent inventory digest must be SHA-256")
    kind_rows = metadata["historyPathKinds"]
    if not isinstance(kind_rows, list) or len(kind_rows) != len(history_paths):
        raise CheckError("history path kind manifest drift")
    expected_kind_rows = [{"path": path, "kind": _path_category(path)} for path in history_paths]
    if kind_rows != expected_kind_rows:
        raise CheckError("history path kind classification drift")
    _validate_counter(
        metadata["historyPathCategoryCounts"],
        Counter(_path_category(path) for path in history_paths),
        "history path category counts",
    )
    final_rows = metadata["finalNetFiles"]
    if not isinstance(final_rows, list) or len(final_rows) != EXPECTED_FINAL_NET_PATHS:
        raise CheckError("final net path count drift")
    final_paths: list[str] = []
    for row in final_rows:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("final net row schema drift")
        path = _safe_path(row["path"])
        final_paths.append(path)
        if path not in history_paths:
            raise CheckError("final net path outside history manifest")
        for field in ("baseSha256", "targetSha256"):
            value = str(row[field])
            if value != "absent" and not SHA64.fullmatch(value):
                raise CheckError(f"invalid {field} for {path}")
    if final_paths != sorted(set(final_paths)):
        raise CheckError("final net path list must be sorted and unique")
    _validate_counter(
        metadata["finalNetCategoryCounts"],
        Counter(_path_category(path) for path in final_paths),
        "final net category counts",
    )
    tree_hashes = metadata["treeHashes"]
    if not isinstance(tree_hashes, dict) or set(tree_hashes) != set(EXACT_SCOPE_ROOTS):
        raise CheckError("tree-hash roots drift")
    for root in EXACT_SCOPE_ROOTS:
        row = tree_hashes[root]
        if not isinstance(row, dict) or set(row) != {"base", "target"} or not all(SHA40.fullmatch(str(v)) for v in row.values()):
            raise CheckError(f"tree hash schema drift: {root}")
    cross_heads = metadata["crossReferenceHeads"]
    expected_cross_heads = {
        ledger: {"ledgerFile": str(config["ledgerFile"]), "head": str(config["head"])}
        for ledger, config in PINNED_LEDGER_HEADS.items()
    }
    if cross_heads != expected_cross_heads:
        raise CheckError("predecessor ledger head drift")
    if metadata["crossReferenceCounts"] != {"authority": 60, "client-wire": 14, "core-runtime": 27}:
        raise CheckError("predecessor cross-reference counts drift")
    if metadata["crossReferenceUnionCount"] != 87:
        raise CheckError("predecessor cross-reference union drift")
    if metadata["predecessorCombinationCounts"] != {
        "authority": 54,
        "authority;core-runtime": 6,
        "client-wire": 6,
        "client-wire;core-runtime": 8,
        "core-runtime": 13,
    }:
        raise CheckError("predecessor combination partition drift")
    slices = metadata["openTalariaSlices"]
    expected_slices = [
        {"id": slice_id, "branch": branch, "head": head}
        for slice_id, (branch, head) in OPEN_SLICE_HEADS.items()
    ]
    if slices != expected_slices:
        raise CheckError("open Talaria slice inventory drift")
    if metadata["pr94"] != PR94:
        raise CheckError("PR94 implementation/not-merged certification state drift")
    assertions = metadata["sourceAssertions"]
    if assertions != SOURCE_ASSERTIONS:
        raise CheckError("source assertion inventory drift")
    entries = _read_tsv(metadata_path.parent / _safe_path(metadata["entriesFile"]), FIELDS)
    if len(entries) != metadata["entryCount"]:
        raise CheckError("entry count mismatch")
    seen: set[str] = set()
    permitted_slices = {"none", *OPEN_SLICE_HEADS, PR94["id"]}
    for row in entries:
        commit = row["commit"]
        if not SHA40.fullmatch(commit) or commit in seen:
            raise CheckError(f"invalid or duplicate commit: {commit}")
        seen.add(commit)
        paths = row["paths"].split(";")
        if paths != sorted(set(paths)) or not paths or any(path not in history_paths for path in paths):
            raise CheckError(f"invalid paths for {commit}")
        if not row["parentCount"].isdigit() or int(row["parentCount"]) < 1:
            raise CheckError(f"invalid parent count for {commit}")
        if row["classification"] not in CLASSIFICATIONS or row["disposition"] not in DISPOSITIONS:
            raise CheckError(f"invalid classification/disposition for {commit}")
        if row["talariaSlice"] not in permitted_slices:
            raise CheckError(f"invalid Talaria slice for {commit}")
        parsed_predecessors = [] if row["predecessors"] == "none" else row["predecessors"].split(";")
        if parsed_predecessors != sorted(set(parsed_predecessors)) or any(key not in PINNED_LEDGER_HEADS for key in parsed_predecessors):
            raise CheckError(f"invalid predecessor names for {commit}")
        if any(not row[field].strip() for field in ("cluster", "contract", "evidence", "required")):
            raise CheckError(f"empty semantic evidence for {commit}")
    _validate_counter(metadata["clusterCounts"], Counter(row["cluster"] for row in entries), "cluster counts")
    _validate_counter(metadata["classificationCounts"], Counter(row["classification"] for row in entries), "classification counts")
    _validate_counter(metadata["dispositionCounts"], Counter(row["disposition"] for row in entries), "disposition counts")
    return metadata, entries


def _verify_entry_inventory(
    metadata: dict[str, Any],
    entries: list[dict[str, str]],
    commits: list[str],
    parent_counts: dict[str, int],
    paths_by_commit: dict[str, set[str]],
    predecessors: dict[str, tuple[str, ...]],
) -> None:
    if len(commits) != metadata["scopedCommitCount"]:
        raise CheckError(f"scoped commit drift: {len(commits)}")
    if sum(parent_counts[commit] > 1 for commit in commits) != metadata["mergeCommitCount"]:
        raise CheckError("merge commit count drift")
    actual_union = sorted(set().union(*paths_by_commit.values()))
    if actual_union != metadata["historyPathUnion"]:
        raise CheckError("history path union drift")
    if _inventory_digest(commits, parent_counts, paths_by_commit) != metadata["everyParentInventorySha256"]:
        raise CheckError("every-parent inventory digest drift")
    entry_map = {row["commit"]: row for row in entries}
    if set(entry_map) != set(commits):
        raise CheckError("commit partition omission or duplicate drift")
    for commit in commits:
        row = entry_map[commit]
        if int(row["parentCount"]) != parent_counts[commit]:
            raise CheckError(f"parent count drift for {commit}")
        if set(row["paths"].split(";")) != paths_by_commit[commit]:
            raise CheckError(f"merge-parent path union drift for {commit}")
        expected = _policy(commit, paths_by_commit[commit], parent_counts[commit], predecessors[commit])
        for field, value in expected.items():
            if row[field] != value:
                raise CheckError(f"classification/disposition policy drift for {commit}: {field}")
    expected_counts = {
        ledger: sum(ledger in predecessors[commit] for commit in commits)
        for ledger in PINNED_LEDGER_HEADS
    }
    if expected_counts != metadata["crossReferenceCounts"]:
        raise CheckError("predecessor cross-reference count drift")
    union_count = sum(bool(predecessors[commit]) for commit in commits)
    if union_count != metadata["crossReferenceUnionCount"]:
        raise CheckError("predecessor cross-reference union drift")
    actual_combinations = _counter_dict(
        ";".join(predecessors[commit]) for commit in commits if predecessors[commit]
    )
    if actual_combinations != metadata["predecessorCombinationCounts"]:
        raise CheckError("predecessor cross-reference combination drift")


def _verify_open_slice_heads(metadata: dict[str, Any]) -> None:
    for row in metadata["openTalariaSlices"]:
        actual = _git(ROOT, "show-ref", "--verify", "--hash", f"refs/heads/{row['branch']}")
        if actual != row["head"]:
            raise CheckError(f"open Talaria slice ref drift: {row['id']}")
    actual_pr94 = _git(ROOT, "show-ref", "--verify", "--hash", f"refs/heads/{PR94['branch']}")
    if actual_pr94 != PR94["head"]:
        raise CheckError("PR94 open branch head drift")
    assertions = [
        ("Packages/Talaria/Sources/TalariaUI/GatewayClient+Models.swift", "boundedDiscountPercent"),
        ("Packages/Talaria/Sources/TalariaUI/Screens/ModelEffortSheet.swift", "ModelPricePresentation"),
        ("Packages/Talaria/Tests/TalariaUITests/ModelManagementContractTests.swift", "testCurrentHermesOxAlphaAliasIsSearchOnly"),
    ]
    for path, contains in assertions:
        body = _git_bytes(ROOT, "show", f"{PR94['head']}:{path}").decode(errors="replace")
        if contains not in body:
            raise CheckError(f"PR94 implementation evidence drift: {path}")


def _verify_source_assertions(metadata: dict[str, Any], checkout: Path) -> None:
    for row in metadata["sourceAssertions"]:
        body = _git_bytes(checkout, "show", f"{EXPECTED_TARGET}:{row['path']}").decode(errors="replace")
        if row["contains"] not in body:
            raise CheckError(f"upstream source assertion drift: {row['path']}")


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path) -> None:
    _git(checkout, "cat-file", "-e", f"{EXPECTED_BASE}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{EXPECTED_TARGET}^{{commit}}")
    commits, parent_counts, paths_by_commit = _scoped_inventory(checkout)
    ledgers = _pinned_ledger_rows()
    predecessors = _predecessors_for(commits, ledgers)
    _verify_entry_inventory(metadata, entries, commits, parent_counts, paths_by_commit, predecessors)
    final_paths = sorted(_git(
        checkout, "diff", "--name-only", f"{EXPECTED_BASE}..{EXPECTED_TARGET}", "--", *EXACT_SCOPE_ROOTS
    ).splitlines())
    final_rows = metadata["finalNetFiles"]
    if final_paths != [row["path"] for row in final_rows]:
        raise CheckError("final net tree drift")
    for row in final_rows:
        for endpoint, field in ((EXPECTED_BASE, "baseSha256"), (EXPECTED_TARGET, "targetSha256")):
            if _blob_hash(checkout, endpoint, row["path"]) != row[field]:
                raise CheckError(f"{field} drift for {row['path']}")
    for root in EXACT_SCOPE_ROOTS:
        expected = metadata["treeHashes"][root]
        if _tree_hash(checkout, EXPECTED_BASE, root) != expected["base"] or _tree_hash(checkout, EXPECTED_TARGET, root) != expected["target"]:
            raise CheckError(f"endpoint tree hash drift: {root}")
    _verify_source_assertions(metadata, checkout)
    _verify_open_slice_heads(metadata)


def _write_tsv(rows: list[dict[str, str]]) -> str:
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=FIELDS, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--checkout", type=Path, help="exact Hermes upstream checkout")
    parser.add_argument("--emit-tsv", action="store_true", help="emit deterministic TSV from --checkout")
    parser.add_argument("--emit-metadata", action="store_true", help="emit deterministic JSON metadata from --checkout")
    args = parser.parse_args(argv)
    try:
        if args.emit_tsv or args.emit_metadata:
            if not args.checkout:
                raise CheckError("--emit-tsv/--emit-metadata requires --checkout")
            if args.emit_tsv:
                rows, *_ = _build_entries(args.checkout)
                print(_write_tsv(rows), end="")
            else:
                print(json.dumps(_build_metadata(args.checkout), indent=2, sort_keys=True))
            return 0
        metadata, entries = load(args.metadata)
        if args.checkout:
            verify_checkout(metadata, entries, args.checkout)
    except CheckError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"OK: {metadata['scopedCommitCount']} scoped commits, {metadata['mergeCommitCount']} merges, "
        f"{metadata['entryCount']} classified rows, {metadata['crossReferenceUnionCount']} predecessor intersections"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
