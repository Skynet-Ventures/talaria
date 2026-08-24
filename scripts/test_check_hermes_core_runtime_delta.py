from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check_hermes_core_runtime_delta.py")
SPEC = importlib.util.spec_from_file_location("core_runtime_delta", SCRIPT)
assert SPEC and SPEC.loader
core_runtime_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(core_runtime_delta)


class CoreRuntimeDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (
            SCRIPT.parents[1]
            / "parity"
            / "hermes-core-runtime-delta-40643cba-057dcdf.json"
        )

    def _copy_fixture(self) -> tuple[Path, dict, list[dict[str, str]]]:
        directory = Path(tempfile.mkdtemp())
        metadata = json.loads(self.source.read_text())
        source_entries = self.source.parent / metadata["entriesFile"]
        entries_path = directory / metadata["entriesFile"]
        entries_path.write_text(source_entries.read_text())
        metadata_path = directory / self.source.name
        metadata_path.write_text(json.dumps(metadata))
        with entries_path.open(newline="") as handle:
            entries = list(csv.DictReader(handle, delimiter="\t"))
        return metadata_path, metadata, entries

    def test_repository_ledger_loads_with_exact_partition(self) -> None:
        metadata, entries = core_runtime_delta.load(self.source)
        self.assertEqual(len(metadata["scopePaths"]), 30)
        self.assertEqual(metadata["scopeCorrection"]["reportedPathCount"], 31)
        self.assertEqual(metadata["scopedCommitCount"], 112)
        self.assertEqual(len(entries), 94)
        self.assertEqual(metadata["crossReferenceCounts"], {
            "authority": 7, "client-wire": 11,
        })
        self.assertEqual(len(metadata["crossReferences"]), 18)
        self.assertEqual(len(metadata["finalNetFiles"]), 30)

    def test_scope_and_partition_drift_fail_closed(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["scopePaths"].pop()
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(core_runtime_delta.CheckError, "scopePaths"):
            core_runtime_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["targetCommit"] = "0" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(core_runtime_delta.CheckError, "exact audited endpoints"):
            core_runtime_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        entries[1]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(core_runtime_delta.CheckError, "duplicate commit"):
            core_runtime_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["crossReferences"][0]["ledgerHead"] = "0" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(core_runtime_delta.CheckError, "ledger head/cluster"):
            core_runtime_delta.load(path)

    def test_classification_and_blocked_contract_drift_fail_closed(self) -> None:
        path, metadata, entries = self._copy_fixture()
        blocked = next(row for row in entries if row["disposition"] == "upstream-contract-blocked")
        blocked["classification"] = "portable-mobile-runtime"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(core_runtime_delta.CheckError, "blocked classification"):
            core_runtime_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["sourceAssertions"][0]["contains"] = "not-a-real-upstream-symbol"
        self._write(path, metadata, entries)
        loaded, loaded_entries = core_runtime_delta.load(path)
        with mock.patch.object(
            core_runtime_delta, "_git_bytes", return_value=b"unrelated source"
        ):
            with self.assertRaisesRegex(core_runtime_delta.CheckError, "source assertion drift"):
                core_runtime_delta._verify_source_assertions(loaded, Path("/exact"))
        self.assertEqual(len(loaded_entries), 94)

    def test_exact_checkout_verifier_rejects_parent_union_and_hash_drift(self) -> None:
        metadata, entries = core_runtime_delta.load(self.source)
        paths_by_commit = {
            row["commit"]: row["paths"].split(";") for row in entries
        }
        paths_by_commit.update({
            row["commit"]: row["paths"] for row in metadata["crossReferences"]
        })
        commits = list(paths_by_commit)
        actual_hashes = {
            (endpoint, row["path"]): row[field]
            for row in metadata["finalNetFiles"]
            for endpoint, field in (
                (metadata["baseCommit"], "baseSha256"),
                (metadata["targetCommit"], "targetSha256"),
            )
        }
        pinned = {"authority": {}, "client-wire": {}}
        for row in metadata["crossReferences"]:
            pinned[row["ledger"]][row["commit"]] = {
                "commit": row["commit"], "cluster": row["ledgerCluster"],
            }

        def fake_git(_checkout: Path, *arguments: str) -> str:
            if arguments[0] == "cat-file":
                return ""
            if arguments[:2] == ("rev-list", "--reverse"):
                return "\n".join(commits)
            if arguments[:3] == ("show", "-s", "--format=%P"):
                return "parent"
            if arguments[:2] == ("diff", "--name-only"):
                if arguments[2] == f"{metadata['baseCommit']}..{metadata['targetCommit']}":
                    return "\n".join(row["path"] for row in metadata["finalNetFiles"])
                return "\n".join(paths_by_commit[arguments[3]])
            raise AssertionError(arguments)

        patches = {
            "_git": mock.patch.object(core_runtime_delta, "_git", side_effect=fake_git),
            "_blob_hash": mock.patch.object(
                core_runtime_delta,
                "_blob_hash",
                side_effect=lambda _checkout, endpoint, path: actual_hashes[(endpoint, path)],
            ),
            "_pinned_ledger_rows": mock.patch.object(
                core_runtime_delta, "_pinned_ledger_rows", return_value=pinned,
            ),
            "_verify_open_slice_heads": mock.patch.object(
                core_runtime_delta, "_verify_open_slice_heads", return_value=None,
            ),
            "_verify_source_assertions": mock.patch.object(
                core_runtime_delta, "_verify_source_assertions", return_value=None,
            ),
        }
        with patches["_git"], patches["_blob_hash"], patches["_pinned_ledger_rows"], patches["_verify_open_slice_heads"], patches["_verify_source_assertions"]:
            core_runtime_delta.verify_checkout(metadata, entries, Path("/exact"))
            entries[0]["paths"] = metadata["scopePaths"][0]
            with self.assertRaisesRegex(core_runtime_delta.CheckError, "merge-parent path union"):
                core_runtime_delta.verify_checkout(metadata, entries, Path("/exact"))

    @staticmethod
    def _write(path: Path, metadata: dict, entries: list[dict[str, str]]) -> None:
        path.write_text(json.dumps(metadata))
        entries_path = path.parent / metadata["entriesFile"]
        with entries_path.open("w", newline="") as handle:
            writer = csv.DictWriter(
                handle, fieldnames=core_runtime_delta.FIELDS, delimiter="\t"
            )
            writer.writeheader()
            writer.writerows(entries)


if __name__ == "__main__":
    unittest.main()
