#!/usr/bin/env python3
"""Validate the exact every-parent residual Hermes runtime delta ledger.

The residual is intentionally not a catch-all.  It subtracts the previously
audited authority, client-wire, core-runtime, Desktop, CLI, and gateway trees,
then inventories every parent side of every remaining merge in the pinned
upstream range.  The TSV is one row per remaining commit and names every
remaining production path for that commit.
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
DEFAULT_METADATA = ROOT / "parity" / "hermes-residual-runtime-delta-40643cba-057dcdf.json"
EXPECTED_REPOSITORY = "https://github.com/nousresearch/hermes-agent.git"
EXPECTED_BASE = "40643cbaf9b767af146694131ffb8f8160f25e1c"
EXPECTED_TARGET = "057dcdf236f8a6a26721c10fcc6ccb72726e272a"
EXPECTED_COUNTS = {
    "scopedCommitCount": 201,
    "scopedMergeCount": 34,
    "historyPathCount": 303,
    "finalNetFileCount": 67,
}
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")

FIELDS = [
    "commit", "paths", "parentCount", "cluster", "classification",
    "disposition", "talariaStatus", "predecessors",
]

# These exact core files belong to the PR93 core-runtime ledger.  Prefix roots
# below deliberately subtract broad client-owned trees; the core ledger itself
# is an exact-file scope.
CORE_RUNTIME_PATHS = frozenset("""agent/agent_runtime_helpers.py
agent/background_review.py
agent/codex_runtime.py
agent/context_compressor.py
agent/conversation_compression.py
agent/conversation_loop.py
agent/error_classifier.py
agent/error_surface.py
agent/gemini_native_adapter.py
agent/interrupt_compat.py
agent/message_sanitization.py
agent/native_compaction.py
agent/review_engine.py
agent/subagent_lifecycle.py
agent/tool_dispatch_helpers.py
agent/tool_executor.py
agent/turn_context.py
agent/turn_finalizer.py
cron/jobs.py
cron/scheduler.py
cron/scheduler_provider.py
run_agent.py
tools/code_execution_tool.py
tools/cronjob_tools.py
tools/delegate_tool.py
tools/interrupt.py
tools/mcp_tool.py
tools/process_registry.py
tools/registry.py
tools/terminal_tool.py""".splitlines())

SCOPE_RULES = {
    "includedRoots": [
        "acp_adapter/", "agent/", "apps/", "cron/", "plugins/", "providers/",
        "tools/", "ui-tui/", "web/",
    ],
    "includedTopLevelPython": True,
    "sourceExtensions": [".py", ".pyi", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".go", ".rs", ".java", ".kt", ".swift"],
    "coveredPrefixExclusions": ["apps/desktop/", "gateway/", "hermes_cli/", "tui_gateway/"],
    "coveredExactExclusions": sorted(CORE_RUNTIME_PATHS),
    "excludedPathComponents": [
        "test", "tests", "__tests__", "fixture", "fixtures", "docs", "doc", "website",
        "locales", "locale", "i18n", "assets", "static", "dist", "build", ".github",
        ".gitlab", "examples", "example", "evals", "benchmarks", "benchmark", "scripts",
        "optional-skills", "contributors", "skills",
    ],
    "excludedExtensions": [
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".svg", ".mp3", ".wav",
        ".ttf", ".otf", ".woff", ".woff2", ".pdf", ".zip", ".tar", ".gz", ".map",
        ".css", ".scss", ".sass", ".less", ".json", ".yaml", ".yml", ".toml", ".lock",
        ".md", ".rst", ".txt", ".po", ".pot",
    ],
    "excludedNames": ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Dockerfile", "Makefile"],
    "excludedNamePatterns": ["test_*", "*_test.py", "*.test.*", "*.spec.*", "*.config.*", "*.d.ts"],
}

PINNED_PREDECESSORS: dict[str, dict[str, Any]] = {
    "authority": {
        "kind": "pinned-git",
        "head": "879078e3ef54d1af2d6e0208105c0cf93c71979c",
        "entriesFile": "parity/hermes-authority-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "disposition", "contract", "evidence", "required"],
    },
    "client-wire": {
        "kind": "pinned-git",
        "head": "69d066bd3c213b8de69fa78735f20327f05f7123",
        "entriesFile": "parity/hermes-client-wire-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "disposition", "impact", "contract", "evidence", "required"],
    },
    "core-runtime": {
        "kind": "pinned-git",
        "head": "7e46a9ab4e68f4f74ecc68fe2222798883a66091",
        "entriesFile": "parity/hermes-core-runtime-delta-40643cba-057dcdf.tsv",
        "fields": ["commit", "paths", "cluster", "classification", "disposition", "talariaSlice", "contract", "evidence", "required"],
    },
}
CURRENT_PREDECESSORS: dict[str, dict[str, Any]] = {
    "desktop-current": {
        "kind": "working-tree-uncommitted",
        "entriesFile": "parity/hermes-desktop-delta-40643cba-057dcdf.tsv",
        "metadataFile": "parity/hermes-desktop-delta-40643cba-057dcdf.json",
        "fields": ["commit", "paths", "parentCount", "cluster", "classification", "disposition", "talariaSlice", "predecessors", "contract", "evidence", "required"],
    },
    "cli-current": {
        "kind": "working-tree-uncommitted",
        "entriesFile": "parity/hermes-cli-delta-40643cba-057dcdf.tsv",
        "metadataFile": "parity/hermes-cli-delta-40643cba-057dcdf.json",
        "fields": ["commit", "paths", "cluster", "classification", "disposition", "talariaStatus", "predecessors"],
    },
    "gateway-platform-current": {
        "kind": "working-tree-uncommitted",
        "entriesFile": "parity/hermes-gateway-platform-delta-40643cba-057dcdf.tsv",
        "metadataFile": "parity/hermes-gateway-platform-delta-40643cba-057dcdf.json",
        "fields": ["commit", "paths", "cluster", "classification", "disposition", "contract", "evidence", "required"],
    },
}
PREDECESSOR_ORDER = tuple(PINNED_PREDECESSORS) + tuple(CURRENT_PREDECESSORS)

CLASSIFICATIONS = {
    "portable-already-covered", "portable-gap", "other-client-only", "host-only",
    "merge-integration", "upstream-contract-blocked",
}
DISPOSITIONS = {
    "covered-by-predecessor-ledger", "covered-by-open-talaria-slice",
    "dynamic-catalog-already-consumed", "merged-to-parent-not-main-uncertified",
    "other-client-only", "host-only", "merge-integration", "upstream-contract-blocked",
}
TALARIA_STATUSES = {
    "none", "predecessor-ledger", "rich-transcript-current", "gateway-heartbeat-current",
    "model-options-current", "message-agent-current", "pr94-parent-merged-not-main-uncertified",
    "authority-blocked",
}

CLUSTER_DEFINITIONS: dict[str, dict[str, str]] = {
    "R01-transcript-and-canonical-state": {
        "classification": "portable-already-covered",
        "disposition": "covered-by-predecessor-ledger",
        "talariaStatus": "rich-transcript-current",
        "contract": "Canonical transcript/session projections remain gateway-owned; phone rendering consumes qualified, hydrated history and never reconstructs state or replays a local mutation.",
        "evidence": "The predecessor wire ledger records the same upstream commits, while Talaria rich-transcript hydration/structured-output heads consume ordered gateway transcript state.",
        "required": "Refresh/reconcile after source-qualified transcript or session events; do not add a second state-repair or compaction mutation path.",
    },
    "R02-gateway-heartbeat": {
        "classification": "portable-already-covered",
        "disposition": "covered-by-open-talaria-slice",
        "talariaStatus": "gateway-heartbeat-current",
        "contract": "Silent socket failure is detected with a bounded gateway.ping heartbeat and socket-generation invalidation; reconnect ownership stays with the client transport.",
        "evidence": "Talaria codex/gateway-heartbeat@e5abb0fae3ca84757631f835495fa1f15bfda016 adds bounded silent-socket detection, immediate foreground validation, early initial-adoption monitoring, superseded-transport retirement, adopted event-authority fencing, bounded OAuth preflight, and fail-closed credential rotation. The full 1,111 XCTest + 39 Swift Testing suite and talaria-verify pass, and the corrected signed build succeeds.",
        "required": "Install the corrected build and complete authenticated sleep/proxy-idle reconnect proof before certification.",
    },
    "R03-model-presentation-pr94": {
        "classification": "portable-already-covered",
        "disposition": "merged-to-parent-not-main-uncertified",
        "talariaStatus": "pr94-parent-merged-not-main-uncertified",
        "contract": "Model identity, provider routing, availability, and prices remain gateway-owned. Search aliases and bounded discount display are presentation-only.",
        "evidence": "PR94 implementation ff0ea1a6e91c3af0996f406dac0acf9f607cc166 was merged into parent branch codex/model-contract-copy as 5cb68d2dd38539b2f5de789e7be95a545437ca22; it covers the Ox Alpha aliases and bounded sale hint without a config mutation.",
        "required": "Complete parent PR67 CI/review, merge the parent to main, and run focused model-contract/device/live-gateway proof before calling PR94 certified.",
    },
    "R04-model-catalog": {
        "classification": "portable-already-covered",
        "disposition": "dynamic-catalog-already-consumed",
        "talariaStatus": "model-options-current",
        "contract": "Provider/model, effort, capability, and price inventory is gateway-declared through model.options; phone code must not create a static provider map or credential mutation from a catalog change.",
        "evidence": "Talaria model-contract-copy@5cb68d2dd38539b2f5de789e7be95a545437ca22 decodes the live model options shape and contains merged PR94 presentation; the range changes host catalog/routing data rather than a new phone wire authority.",
        "required": "Refresh model.options and retain gateway IDs; any provider credential or config write needs separately bounded authenticated authority.",
    },
    "R05-a2a-canonical-transcript": {
        "classification": "portable-already-covered",
        "disposition": "covered-by-predecessor-ledger",
        "talariaStatus": "message-agent-current",
        "contract": "Bot-mode agent-to-agent delivery, retry, and failure classification run in Hermes; Talaria consumes only the canonical bounded transcript/feed projection and never fabricates tool calls.",
        "evidence": "PR85 authority rows cover the structured A2A commits and codex/current-hermes-message-agent-projection-v2@d6024e26a805c35f9cba91c0c6b1c9e9813f13b4 preserves qualified sender identity.",
        "required": "Use canonical Bot Chat and prove local/foreign/refused/timeout delivery without exposing credentials or synthesizing A2A mutations.",
    },
    "R06-one-shot-rearm-blocked": {
        "classification": "upstream-contract-blocked",
        "disposition": "upstream-contract-blocked",
        "talariaStatus": "authority-blocked",
        "contract": "The new host rearm_oneshot operation has no authenticated mobile wire action: cron.manage admits remove, pause, and resume only, and generic update cannot safely activate a terminal one-shot.",
        "evidence": "a0ca7c19204e514f9590ce3b812e029b315ab9e9 adds cron.jobs.rearm_oneshot while target tui_gateway/methods_tools.py has no rearm action.",
        "required": "Hermes must add an authenticated profile-scoped canonical-job rearm action with exactly one server-now or bounded ISO run_at, server-side one-shot/live-claim checks, canonical job/profile postcondition, and revision or mutation receipt. Then base a narrow client slice on codex/current-hermes-cron-push-isolation@28e9f713e4aa46fc78fbaa1ef19abf0892ff3c8e.",
    },
    "R07-auxiliary-model-administration-blocked": {
        "classification": "upstream-contract-blocked",
        "disposition": "upstream-contract-blocked",
        "talariaStatus": "authority-blocked",
        "contract": "The dashboard review-slot label does not authorize a phone auxiliary-model editor, credential flow, generic config write, or restart.",
        "evidence": "codex/auxiliary-model-administration@ebc1c577887c1f98e992a9900cbb43a4f95fe6e9 records that current auxiliary/config routes lack a safe revisioned, secret-safe mobile contract.",
        "required": "Require a bounded profile-scoped auxiliary snapshot with declared task/field/range/options, write-only credentials plus configured/clear facts, profile/task/expected-revision mutations with 409 and canonical postcondition, finite field bounds, and a change/refresh contract.",
    },
    "R08-learned-memory-blocked": {
        "classification": "upstream-contract-blocked",
        "disposition": "upstream-contract-blocked",
        "talariaStatus": "authority-blocked",
        "contract": "Host memory-provider timestamp/runtime changes do not authorize learned-memory graph/detail/edit/delete/import/export on a phone.",
        "evidence": "The exact authority audit at ebc1c577 documents unbounded graph/detail payloads, no stable row revisions, and no safe import/export or refresh contract at the target endpoint.",
        "required": "Require bounded profile-scoped snapshots with immutable ids/revisions, bounded secret-safe detail, expected-revision edit/archive/delete with canonical postconditions, bounded prepare/commit import-export, and a source-change/refresh contract.",
    },
    "R09-other-client-only": {
        "classification": "other-client-only",
        "disposition": "other-client-only",
        "talariaStatus": "none",
        "contract": "This behavior belongs to the dashboard, terminal TUI, ACP, bootstrap installer, browser controller, voice desktop client, or third-party platform adapter rather than the phone client.",
        "evidence": "The paths are confined to another client runtime or its host adapter; no new bounded authenticated Talaria endpoint is introduced.",
        "required": "Keep client-specific behavior in its owning surface and retain its upstream/host verification; do not port controller, shell, or platform credentials to Talaria.",
    },
    "R10-host-runtime": {
        "classification": "host-only",
        "disposition": "host-only",
        "talariaStatus": "none",
        "contract": "This is Hermes local runtime, scheduling, storage, plugin, provider, tool, process, or security behavior; it has no newly bounded authenticated mobile contract.",
        "evidence": "The residual source change executes on the host and either has no gateway endpoint or would require a separate authority audit before client mutation/UI work.",
        "required": "Verify on the host. Do not infer a mobile request, credential surface, config mutation, restart, or local-host behavior from this implementation detail.",
    },
    "M01-merge-integration": {
        "classification": "merge-integration",
        "disposition": "merge-integration",
        "talariaStatus": "predecessor-ledger",
        "contract": "This row records the literal union of every parent diff for a merge; it is not a separate mobile implementation claim.",
        "evidence": "Every-parent inventory preserves the merge paths and predecessor intersections so integrated work cannot disappear from the audit.",
        "required": "Use the direct commits and named predecessor rows for behavior-specific proof; retain this row for topology/accounting.",
    },
}

# Only these direct commits have a phone-relevant outcome after scope subtraction.
# Everything else is classified by exact owning runtime below rather than being
# silently folded into a broad platform bucket.
TRANSCRIPT_COMMITS = {
    "3e5e4c5d20006e0f29f5389224ee0265e444dd3f",
    "fb27614addac115d55299bc6538ae112fd01f688",
    "fd41164861575f5564cdb091dc16204d0f49883",
    "a2a23a8f7e30e644702459cfe0c4c74897524cfd",
    "26a4f89ada5dc62980b4aa1666397dcc6e9f5101",
    "80b202f53aa719eebb73ae1af596fa806f7768d3",
    "4aa162b30d44967f5fd4b1f2315d258d10461702",
    "d3e4b50e68b8bc0f202ef1ba8f11d4f051f2c791",
    "47d6ce78a24920a5f1baa51332efb8b45d1fef19",
}
HEARTBEAT_COMMITS = {
    "9153be2a5126f8280839a58d143ddcf80afc6d12",
    "e3f695e5e00ef8718d8829fbe44fd3d2e36ed236",
}
PR94_COMMITS = {"1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4"}
MODEL_CATALOG_COMMITS = {
    "1017a5627475dd490374abaea895f200a120d7d5",
    "c01cd26f959fb7c5bb21c89130d1d83c50012d0d",
    "28a9b6c565b1490aca79c10a6aae6d851a550a84",
    "ca06b8768999c32f0af2a7bf4542678dd883cf79",
    "54227416ce1ad0de8b53c85dd994e1b4d0941074",
    "d4d04098a5f9afb526f0995c1eb08648d92095a7",
    "30ccd01ba2a7dbf66e93bdd6f0dada663eff7150",
    "624723130b50b64b291b9c538fae5ba3638abca5",
    "f8e5949f61f2b519ff1b937ff3d6f745a11327b9",
    "01d8562fce28a77362e3e3ce7797f3aae57b1985",
    "30f9955a44ec17f3d07100a008b9c2e2689a16bf",
    "e5b96fcb10077f0b6ffaa06de6516dfcc510d992",
    "16476fad10e84c52767881d644c235a537e256e6",
    "41ca67c5b13489272150d1250bb1e4d5a0a19178",
    "5cb7b521cfa7a10380834d8e637aa7800441fbe0",
    "ad96d2e2d9257a91bffb5f9d9affbf89a7669284",
    "8a949659c3e5705fe6b6e16b611a7600dbf091de",
    "b6bcb3e791c673e63974029bbab40cc9326803ff",
    "b9f17ba3f10a9947ba69a5ab6cc4faa938235a44",
    "5f0a8f8739a0d993dc60dbd3c070ef883ed26964",
    "63a9c26fbe6ca50138814111c21a4f4550ea85c1",
    "7b89e177745fab390d2e7bdbf5e231bf164be24f",
    "933c209e96630a6026b0a18ecf6a86e65110f5b8",
    "394f0f0902b6168df733a8c655eb59753b74e94e",
    "4d729e4b31c5c39bb6b1f351a0c3928909db45dc",
    "c9e2a46df60ed22fd78207b7d8594449d85f9528",
}
A2A_COMMITS = {
    "e26d91dc11ea32f2f1af2c9778d424172f834431",
    "d3e087fd8c2441577bac614c755ec46a1c4e7ee8",
    "eaa61ff62d556055542cd9fb10857d3d53a2f9f5",
    "0ae18cdae022e5071b318b797bf896e8c7c97057",
    "08742d0e32a1a3b7e9a795fe5d0923064bcbb0c6",
    "793fba428ade996975cb300eb3aa512ebe6ffb41",
    "764dba69532e2ead23f57c2db3998ec007a3d3ce",
    "64eb6bb7fc029ba03331abac379288c30b9e2157",
    "6994851694a98c9078bd90f7bc562f7b33f9bb51",
    "b96369212c2219acb3b13ba201945e22f4e8a543",
    "ac3f9a2dc4fe20fc24c1cfbdabf500a9d2b41ef3",
    "c460e87d10def7cf0c11b3b045156147b40c3dd5",
    "bef31fb06bbfae3e2ded660e0aceafe35399eca2",
    "4865194772e6af2af7ac974f73b6f50454264cb5",
    "b274b346d846fdd38ac650ebf00c50b84ad00ee2",
    "c584d15cdc31e1ebf3989c426ed05fb2ddb0c9fc",
    "c099ef05de6281f7841a88754443de29f0dd4b9a",
    "42a6d761d2dc7dc2b618c26ca10983896a5186de",
    "2912c36aa41c2e33f3f61d16de0a3897a1e6cef1",
}
REARM_COMMIT = "a0ca7c19204e514f9590ce3b812e029b315ab9e9"
AUXILIARY_BLOCKED_COMMIT = "65c58651b0e34ab3d2c25b7024609ef9c7b7ffef"
MEMORY_BLOCKED_COMMITS = {
    "97850afa333d83e9161a5a9d9df31c8f6d659688",
    "497d6d5a66d45e66903d8f24c2f9f6d9af75dfd5",
    "32fb12a2353df39c7c43cbc027bf220426efe281",
}
OTHER_CLIENT_COMMITS = {
    "5df1d0e113279a892e4eec401a437f443f7a245c",
    "d524cc9a16e13be42762984d21c1e4d19fbce24e",
    "095a1d078c5c1cf7a55d47cafc50179fc463e790",
    "2039b572f5ea0cf9cefeeb74a640785e25305f03",
    "a5882058de7db8c34bf6d72f05c42183b08ab46b",
    "10f0d2278bf7ea7dd005e5c8b1b9dc47d108a1ec",
    "165d1849e25c7653a4c1879ca8410475eb8a7d52",
}


class CheckError(RuntimeError):
    pass


def _git(checkout: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(["git", "-C", str(checkout), *arguments], check=True,
                                capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise CheckError(f"git {' '.join(arguments)} failed: {str(detail).strip()}") from error
    return result.stdout.strip()


def _git_bytes(checkout: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(["git", "-C", str(checkout), *arguments], check=True,
                                capture_output=True, timeout=90)
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


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _hash_paths(paths: list[str]) -> str:
    return _sha256_bytes(("\n".join(paths) + "\n").encode())


def _is_residual_production_path(path: str) -> bool:
    candidate = Path(path)
    name = candidate.name
    parts = candidate.parts
    if not path or candidate.is_absolute() or ".." in parts:
        return False
    if path.startswith(tuple(SCOPE_RULES["coveredPrefixExclusions"])) or path in CORE_RUNTIME_PATHS:
        return False
    if set(parts) & set(SCOPE_RULES["excludedPathComponents"]):
        return False
    if name.startswith("test_") or name.endswith("_test.py") or ".test." in name or ".spec." in name:
        return False
    if name in set(SCOPE_RULES["excludedNames"]) or ".config." in name or name.endswith(".d.ts"):
        return False
    if candidate.suffix.lower() in set(SCOPE_RULES["excludedExtensions"]):
        return False
    in_root = any(path.startswith(root) for root in SCOPE_RULES["includedRoots"])
    top_level_python = bool(SCOPE_RULES["includedTopLevelPython"]) and len(parts) == 1 and candidate.suffix == ".py"
    return (in_root or top_level_python) and candidate.suffix in set(SCOPE_RULES["sourceExtensions"])


def _inventory(metadata: dict[str, Any], checkout: Path) -> tuple[list[str], dict[str, set[str]], dict[str, int]]:
    commits: list[str] = []
    paths_by_commit: dict[str, set[str]] = {}
    parent_counts: dict[str, int] = {}
    for commit in _git(checkout, "rev-list", "--reverse", f"{metadata['baseCommit']}..{metadata['targetCommit']}").splitlines():
        parents = _git(checkout, "show", "-s", "--format=%P", commit).split()
        changed: set[str] = set()
        for parent in parents:
            changed.update(_git(checkout, "diff", "--name-only", parent, commit).splitlines())
        residual = {path for path in changed if _is_residual_production_path(path)}
        if residual:
            commits.append(commit)
            paths_by_commit[commit] = residual
            parent_counts[commit] = len(parents)
    return commits, paths_by_commit, parent_counts


OTHER_CLIENT_PATH_PREFIXES = (
    "acp_adapter/", "apps/bootstrap-installer/", "plugins/kanban/dashboard/",
    "plugins/platforms/", "plugins/teams_pipeline/", "ui-tui/", "web/",
)


def _cluster_for(commit: str, parent_count: int, paths: set[str]) -> str:
    if parent_count > 1:
        return "M01-merge-integration"
    if commit == REARM_COMMIT:
        return "R06-one-shot-rearm-blocked"
    if commit == AUXILIARY_BLOCKED_COMMIT:
        return "R07-auxiliary-model-administration-blocked"
    if commit in MEMORY_BLOCKED_COMMITS:
        return "R08-learned-memory-blocked"
    if commit in TRANSCRIPT_COMMITS:
        return "R01-transcript-and-canonical-state"
    if commit in HEARTBEAT_COMMITS:
        return "R02-gateway-heartbeat"
    if commit in PR94_COMMITS:
        return "R03-model-presentation-pr94"
    if commit in MODEL_CATALOG_COMMITS:
        return "R04-model-catalog"
    if commit in A2A_COMMITS:
        return "R05-a2a-canonical-transcript"
    if commit in OTHER_CLIENT_COMMITS:
        return "R09-other-client-only"
    if any(path.startswith(OTHER_CLIENT_PATH_PREFIXES) for path in paths):
        return "R09-other-client-only"
    return "R10-host-runtime"


def _blob_hash(checkout: Path, commit: str, path: str) -> str:
    if _git(checkout, "ls-tree", "--name-only", commit, "--", path) != path:
        return "absent"
    return _sha256_bytes(_git_bytes(checkout, "show", f"{commit}:{path}"))


def _expected_predecessor_metadata() -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for name, value in PINNED_PREDECESSORS.items():
        result[name] = {key: value[key] for key in ("kind", "head", "entriesFile")}
    return result


def _read_predecessor_rows(metadata: dict[str, Any]) -> dict[str, dict[str, dict[str, str]]]:
    records = metadata["predecessorLedgers"]
    result: dict[str, dict[str, dict[str, str]]] = {}
    for name, expected in PINNED_PREDECESSORS.items():
        record = records[name]
        if record != _expected_predecessor_metadata()[name]:
            raise CheckError(f"pinned predecessor metadata drift: {name}")
        _local_git("cat-file", "-e", f"{record['head']}^{{commit}}")
        text = _local_git("show", f"{record['head']}:{record['entriesFile']}")
        rows = _read_tsv_text(text, expected["fields"], f"{name} predecessor ledger")
        result[name] = {row["commit"]: row for row in rows}
    for name, expected in CURRENT_PREDECESSORS.items():
        record = records[name]
        if set(record) != {"kind", "entriesFile", "metadataFile", "entriesSha256", "metadataSha256"}:
            raise CheckError(f"current predecessor metadata fields drift: {name}")
        if record["kind"] != expected["kind"] or record["entriesFile"] != expected["entriesFile"] or record["metadataFile"] != expected["metadataFile"]:
            raise CheckError(f"current predecessor metadata drift: {name}")
        entries_path = ROOT / _safe_path(record["entriesFile"])
        metadata_path = ROOT / _safe_path(record["metadataFile"])
        try:
            entries_bytes = entries_path.read_bytes()
            current_metadata_bytes = metadata_path.read_bytes()
        except OSError as error:
            raise CheckError(f"cannot read current predecessor {name}: {error}") from error
        if record["entriesSha256"] != _sha256_bytes(entries_bytes) or record["metadataSha256"] != _sha256_bytes(current_metadata_bytes):
            raise CheckError(f"current predecessor hash drift: {name}")
        current_metadata = _read_json(metadata_path)
        if current_metadata.get("repository") != EXPECTED_REPOSITORY or current_metadata.get("baseCommit") != EXPECTED_BASE or current_metadata.get("targetCommit") != EXPECTED_TARGET:
            raise CheckError(f"current predecessor range drift: {name}")
        if current_metadata.get("entriesFile") != Path(expected["entriesFile"]).name:
            raise CheckError(f"current predecessor entries file drift: {name}")
        rows = _read_tsv_text(entries_bytes.decode("utf-8"), expected["fields"], f"{name} predecessor ledger")
        result[name] = {row["commit"]: row for row in rows}
    return result


def _expected_predecessor_value(commit: str, predecessor_rows: dict[str, dict[str, dict[str, str]]]) -> str:
    matches = [f"{name}:{predecessor_rows[name][commit]['cluster']}" for name in PREDECESSOR_ORDER if commit in predecessor_rows[name]]
    return ";".join(matches) if matches else "none"


def _render_rows(metadata: dict[str, Any], checkout: Path, predecessor_rows: dict[str, dict[str, dict[str, str]]]) -> list[dict[str, str]]:
    commits, paths_by_commit, parent_counts = _inventory(metadata, checkout)
    rows: list[dict[str, str]] = []
    for commit in commits:
        cluster = _cluster_for(commit, parent_counts[commit], paths_by_commit[commit])
        definition = CLUSTER_DEFINITIONS[cluster]
        rows.append({
            "commit": commit,
            "paths": ";".join(sorted(paths_by_commit[commit])),
            "parentCount": str(parent_counts[commit]),
            "cluster": cluster,
            "classification": definition["classification"],
            "disposition": definition["disposition"],
            "talariaStatus": definition["talariaStatus"],
            "predecessors": _expected_predecessor_value(commit, predecessor_rows),
        })
    return rows


def _validate_counter(value: object, expected: Counter[str], name: str) -> None:
    if not isinstance(value, dict) or value != dict(expected):
        raise CheckError(f"{name} drift")


def _validate_talaria_references(metadata: dict[str, Any]) -> None:
    refs = metadata["talariaReferences"]
    expected = {
        "rich-transcript-hydration": ("codex/rich-transcript-hydration", "d5bad705f1c19d716eea4abb8de1ba4206659dde", "99c203cd516491d94d255b46943315a5169f39a1"),
        "rich-transcript-structured-output": ("codex/rich-transcript-structured-output", "fdee839fdc1fda8a4a8233ff5e459795d09752b0", "79ccf0f5aaaaa8fac2efd742aba1a4a7a720c649"),
        "gateway-heartbeat": ("codex/gateway-heartbeat", "e5abb0fae3ca84757631f835495fa1f15bfda016", "5658b57c21c45a5b9c6108c7de55439984e0a40f"),
        "model-contract-copy": ("codex/model-contract-copy", "5cb68d2dd38539b2f5de789e7be95a545437ca22", "27a12f11c3825cc8ada4860b60e298acdcc4fa37 ff0ea1a6e91c3af0996f406dac0acf9f607cc166"),
        "message-agent-projection-v2": ("codex/current-hermes-message-agent-projection-v2", "d6024e26a805c35f9cba91c0c6b1c9e9813f13b4", "f332d263d9bb2d5a53feed3727a52a5e2dd89c88"),
        "mcp-live-reload": ("codex/mcp-live-reload", "9851fca979f40b08df283855de290de4e3f04568", "ccb945a03bc1f9dda9a50b151becef8636fa88f4"),
        "auxiliary-model-administration": ("codex/auxiliary-model-administration", "ebc1c577887c1f98e992a9900cbb43a4f95fe6e9", "1ec216d77e156f72d6184b82c252cdff26bb6eda"),
        "PR94-model-discount-presentation": ("codex/model-contract-copy", "5cb68d2dd38539b2f5de789e7be95a545437ca22", "27a12f11c3825cc8ada4860b60e298acdcc4fa37 ff0ea1a6e91c3af0996f406dac0acf9f607cc166"),
    }
    if not isinstance(refs, list) or len(refs) != len(expected):
        raise CheckError("Talaria reference inventory drift")
    seen: set[str] = set()
    for row in refs:
        if not isinstance(row, dict) or set(row) != {"id", "branch", "commit", "parent", "state", "upstreamCommits", "note"}:
            raise CheckError("Talaria reference fields drift")
        identifier = str(row["id"])
        if identifier not in expected or identifier in seen:
            raise CheckError("unknown or duplicate Talaria reference")
        seen.add(identifier)
        branch, commit, parent = expected[identifier]
        if row["branch"] != branch or row["commit"] != commit or row["parent"] != parent:
            raise CheckError(f"Talaria reference drift: {identifier}")
        if not isinstance(row["state"], str) or not row["state"].strip() or not isinstance(row["note"], str) or not row["note"].strip():
            raise CheckError(f"Talaria reference evidence missing: {identifier}")
        commits = row["upstreamCommits"]
        if not isinstance(commits, list) or any(not SHA40.fullmatch(str(value)) for value in commits):
            raise CheckError(f"Talaria reference upstream commits invalid: {identifier}")
    if seen != set(expected):
        raise CheckError("Talaria reference set drift")


def load(metadata_path: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    metadata = _read_json(metadata_path)
    required = {
        "schemaVersion", "repository", "baseCommit", "targetCommit", "scopeRules", "exclusionJustifications",
        "scopedCommitCount", "scopedMergeCount", "entryCount", "entriesFile", "historyPathCount", "historyPathSha256",
        "finalNetFiles", "endpointHashes", "clusterDefinitions", "clusterCounts", "classificationCounts",
        "dispositionCounts", "talariaStatusCounts", "predecessorLedgers", "predecessorCounts", "talariaReferences",
        "sourceAssertions", "sourceAbsenceAssertions", "findings",
    }
    if set(metadata) != required or metadata["schemaVersion"] != 1:
        raise CheckError("metadata keys/schemaVersion do not match schema 1")
    if metadata["repository"] != EXPECTED_REPOSITORY or metadata["baseCommit"] != EXPECTED_BASE or metadata["targetCommit"] != EXPECTED_TARGET:
        raise CheckError("exact upstream authority drift")
    if metadata["scopeRules"] != SCOPE_RULES:
        raise CheckError("residual scope rules drift")
    justifications = metadata["exclusionJustifications"]
    if not isinstance(justifications, list) or len(justifications) != 11:
        raise CheckError("exclusion justification inventory drift")
    seen_exclusions: set[str] = set()
    for row in justifications:
        if not isinstance(row, dict) or set(row) != {"category", "rule", "reason"} or not all(isinstance(row[key], str) and row[key] for key in row):
            raise CheckError("invalid exclusion justification")
        if row["category"] in seen_exclusions:
            raise CheckError("duplicate exclusion justification")
        seen_exclusions.add(row["category"])
    expected_categories = {"authority", "client-wire", "core-runtime", "desktop", "cli", "gateway-platform", "tests-fixtures", "docs-locales", "styles-assets", "build-config-lock", "non-runtime"}
    if seen_exclusions != expected_categories:
        raise CheckError("exclusion categories drift")
    for field, expected in EXPECTED_COUNTS.items():
        if field == "finalNetFileCount":
            continue
        if metadata[field] != expected:
            raise CheckError(f"exact inventory count drift: {field}")
    if metadata["entriesFile"] != "hermes-residual-runtime-delta-40643cba-057dcdf.tsv":
        raise CheckError("entries file drift")
    if not SHA64.fullmatch(str(metadata["historyPathSha256"])):
        raise CheckError("invalid history path hash")
    if metadata["clusterDefinitions"] != CLUSTER_DEFINITIONS:
        raise CheckError("cluster definitions drift")

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
        if not paths or paths != sorted(set(paths)) or any(not _is_residual_production_path(path) for path in paths):
            raise CheckError(f"invalid residual paths for {commit}")
        if row["parentCount"] not in {"1", "2", "3", "4"}:
            raise CheckError(f"invalid parent count for {commit}")
        definition = CLUSTER_DEFINITIONS.get(row["cluster"])
        if definition is None:
            raise CheckError(f"unknown cluster for {commit}")
        for field in ("classification", "disposition", "talariaStatus"):
            if row[field] != definition[field]:
                raise CheckError(f"cluster semantics drift for {commit}")
        if row["classification"] not in CLASSIFICATIONS or row["disposition"] not in DISPOSITIONS or row["talariaStatus"] not in TALARIA_STATUSES:
            raise CheckError(f"unknown row semantics for {commit}")
        if row["predecessors"] != "none" and not re.fullmatch(r"(?:authority|client-wire|core-runtime|desktop-current|cli-current|gateway-platform-current):[^;]+(?:;(?:authority|client-wire|core-runtime|desktop-current|cli-current|gateway-platform-current):[^;]+)*", row["predecessors"]):
            raise CheckError(f"invalid predecessor reference for {commit}")
    _validate_counter(metadata["clusterCounts"], Counter(row["cluster"] for row in entries), "clusterCounts")
    _validate_counter(metadata["classificationCounts"], Counter(row["classification"] for row in entries), "classificationCounts")
    _validate_counter(metadata["dispositionCounts"], Counter(row["disposition"] for row in entries), "dispositionCounts")
    _validate_counter(metadata["talariaStatusCounts"], Counter(row["talariaStatus"] for row in entries), "talariaStatusCounts")
    if metadata["classificationCounts"].get("portable-gap", 0) != 0:
        raise CheckError("portable-gap count must be zero until an actionable authority-backed gap exists")

    final_rows = metadata["finalNetFiles"]
    if not isinstance(final_rows, list) or len(final_rows) != EXPECTED_COUNTS["finalNetFileCount"]:
        raise CheckError("final net manifest drift")
    final_paths: list[str] = []
    for row in final_rows:
        if not isinstance(row, dict) or set(row) != {"path", "baseSha256", "targetSha256"}:
            raise CheckError("final net manifest fields drift")
        path = _safe_path(row["path"])
        if not _is_residual_production_path(path):
            raise CheckError(f"non-residual final net path: {path}")
        if any(value != "absent" and not SHA64.fullmatch(str(value)) for value in (row["baseSha256"], row["targetSha256"])):
            raise CheckError(f"invalid final net hash: {path}")
        final_paths.append(path)
    if final_paths != sorted(set(final_paths)):
        raise CheckError("final net paths must be sorted and unique")

    endpoint_rows = metadata["endpointHashes"]
    if not isinstance(endpoint_rows, list) or len(endpoint_rows) != 9:
        raise CheckError("endpoint hash inventory drift")
    endpoints: set[str] = set()
    for row in endpoint_rows:
        if not isinstance(row, dict) or set(row) != {"path", "purpose", "baseSha256", "targetSha256"}:
            raise CheckError("endpoint hash fields drift")
        path = _safe_path(row["path"])
        if path in endpoints or not isinstance(row["purpose"], str) or not row["purpose"].strip():
            raise CheckError("endpoint hash path/purpose drift")
        endpoints.add(path)
        if any(value != "absent" and not SHA64.fullmatch(str(value)) for value in (row["baseSha256"], row["targetSha256"])):
            raise CheckError(f"invalid endpoint hash: {path}")

    expected_pins = _expected_predecessor_metadata()
    ledgers = metadata["predecessorLedgers"]
    if not isinstance(ledgers, dict) or set(ledgers) != set(PREDECESSOR_ORDER):
        raise CheckError("predecessor ledger set drift")
    for name, pin in expected_pins.items():
        if ledgers[name] != pin:
            raise CheckError(f"pinned predecessor ledger drift: {name}")
    for name, current in CURRENT_PREDECESSORS.items():
        record = ledgers[name]
        if not isinstance(record, dict) or record.get("kind") != current["kind"]:
            raise CheckError(f"current predecessor ledger drift: {name}")
        if not SHA64.fullmatch(str(record.get("entriesSha256", ""))) or not SHA64.fullmatch(str(record.get("metadataSha256", ""))):
            raise CheckError(f"current predecessor hash syntax drift: {name}")
    counts = metadata["predecessorCounts"]
    if not isinstance(counts, dict) or set(counts) != set(PREDECESSOR_ORDER) or any(not isinstance(value, int) or value < 0 for value in counts.values()):
        raise CheckError("predecessor count manifest drift")
    _validate_talaria_references(metadata)

    for key, expected_field in (("sourceAssertions", "contains"), ("sourceAbsenceAssertions", "notContains")):
        assertions = metadata[key]
        if not isinstance(assertions, list) or len(assertions) < 3:
            raise CheckError(f"{key} missing")
        for row in assertions:
            if not isinstance(row, dict) or set(row) != {"path", expected_field, "description"}:
                raise CheckError(f"{key} fields drift")
            _safe_path(row["path"])
            if not isinstance(row[expected_field], str) or not row[expected_field] or not isinstance(row["description"], str) or not row["description"]:
                raise CheckError(f"{key} values drift")
    findings = metadata["findings"]
    if not isinstance(findings, list) or len(findings) != 4:
        raise CheckError("findings inventory drift")
    for row in findings:
        if not isinstance(row, dict) or set(row) != {"id", "classification", "status", "evidence", "required"}:
            raise CheckError("finding fields drift")
        if row["classification"] not in CLASSIFICATIONS or any(not isinstance(row[field], str) or not row[field] for field in ("id", "status", "evidence", "required")):
            raise CheckError("finding values drift")
    return metadata, entries


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


def _verify_talaria_references(metadata: dict[str, Any]) -> None:
    for row in metadata["talariaReferences"]:
        _local_git("cat-file", "-e", f"{row['commit']}^{{commit}}")
        if _local_git("show", "-s", "--format=%P", row["commit"]) != row["parent"]:
            raise CheckError(f"Talaria reference parent drift: {row['id']}")


def verify_checkout(metadata: dict[str, Any], entries: list[dict[str, str]], checkout: Path) -> None:
    _git(checkout, "cat-file", "-e", f"{metadata['baseCommit']}^{{commit}}")
    _git(checkout, "cat-file", "-e", f"{metadata['targetCommit']}^{{commit}}")
    predecessor_rows = _read_predecessor_rows(metadata)
    expected_rows = _render_rows(metadata, checkout, predecessor_rows)
    if entries != expected_rows:
        raise CheckError("every-parent inventory, path union, cluster, or predecessor cross-reference drift")
    history_paths = sorted({path for row in expected_rows for path in row["paths"].split(";")})
    if len(history_paths) != metadata["historyPathCount"] or _hash_paths(history_paths) != metadata["historyPathSha256"]:
        raise CheckError("history path union drift")
    if sum(row["parentCount"] != "1" for row in expected_rows) != metadata["scopedMergeCount"]:
        raise CheckError("merge union count drift")
    source_counts = Counter()
    for row in expected_rows:
        if row["predecessors"] != "none":
            for part in row["predecessors"].split(";"):
                source_counts[part.split(":", 1)[0]] += 1
    if dict(source_counts) != metadata["predecessorCounts"]:
        raise CheckError("predecessor intersection count drift")
    net_paths = sorted(path for path in _git(checkout, "diff", "--name-only", f"{metadata['baseCommit']}..{metadata['targetCommit']}").splitlines() if _is_residual_production_path(path))
    if net_paths != [row["path"] for row in metadata["finalNetFiles"]]:
        raise CheckError("final net path drift")
    for row in metadata["finalNetFiles"] + metadata["endpointHashes"]:
        for endpoint, field in ((metadata["baseCommit"], "baseSha256"), (metadata["targetCommit"], "targetSha256")):
            if _blob_hash(checkout, str(endpoint), row["path"]) != row[field]:
                raise CheckError(f"{field} drift for {row['path']}")
    _verify_source_assertions(metadata, checkout)
    _verify_talaria_references(metadata)


def _print_rows(rows: list[dict[str, str]]) -> None:
    writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--checkout", type=Path, help="exact Hermes upstream checkout")
    parser.add_argument("--render-tsv", action="store_true", help="render expected TSV (requires --checkout)")
    args = parser.parse_args(argv)
    try:
        if args.render_tsv:
            if not args.checkout:
                raise CheckError("--render-tsv requires --checkout")
            metadata = _read_json(args.metadata)
            predecessor_rows = _read_predecessor_rows(metadata)
            _print_rows(_render_rows(metadata, args.checkout, predecessor_rows))
            return 0
        metadata, entries = load(args.metadata)
        if args.checkout:
            verify_checkout(metadata, entries, args.checkout)
    except CheckError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"OK: {metadata['scopedCommitCount']} scoped commits, "
        f"{metadata['historyPathCount']} residual production paths, "
        f"{sum(metadata['predecessorCounts'].values())} predecessor references"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
