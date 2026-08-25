from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_hermes_desktop_delta.py")
SPEC = importlib.util.spec_from_file_location("desktop_delta", SCRIPT)
assert SPEC and SPEC.loader
desktop_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(desktop_delta)


class DesktopDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (
            SCRIPT.parents[1]
            / "parity"
            / "hermes-desktop-delta-40643cba-057dcdf.json"
        )

    def _fixture(self) -> tuple[Path, dict, list[dict[str, str]]]:
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

    @staticmethod
    def _write(path: Path, metadata: dict, entries: list[dict[str, str]]) -> None:
        path.write_text(json.dumps(metadata))
        with (path.parent / metadata["entriesFile"]).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=desktop_delta.FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(entries)

    @staticmethod
    def _inventory(entries: list[dict[str, str]]) -> tuple[
        list[str], dict[str, int], dict[str, set[str]], dict[str, tuple[str, ...]]
    ]:
        commits = [row["commit"] for row in entries]
        parent_counts = {row["commit"]: int(row["parentCount"]) for row in entries}
        paths_by_commit = {row["commit"]: set(row["paths"].split(";")) for row in entries}
        predecessors = {
            row["commit"]: (() if row["predecessors"] == "none" else tuple(row["predecessors"].split(";")))
            for row in entries
        }
        return commits, parent_counts, paths_by_commit, predecessors

    def test_repository_ledger_loads_with_exact_inventory(self) -> None:
        metadata, entries = desktop_delta.load(self.source)
        self.assertEqual(metadata["scopeRoots"], ["apps/desktop/src", "apps/desktop/electron"])
        self.assertEqual(metadata["scopedCommitCount"], 241)
        self.assertEqual(metadata["mergeCommitCount"], 34)
        self.assertEqual(len(entries), 241)
        self.assertEqual(len(metadata["historyPathUnion"]), 1072)
        self.assertEqual(len(metadata["historyPathKinds"]), 1072)
        self.assertEqual(len(metadata["finalNetFiles"]), 345)
        self.assertEqual(metadata["crossReferenceCounts"], {
            "authority": 60, "client-wire": 14, "core-runtime": 27,
        })
        self.assertEqual(metadata["crossReferenceUnionCount"], 87)
        self.assertEqual(metadata["pr94"]["head"], "5cb68d2dd38539b2f5de789e7be95a545437ca22")
        self.assertEqual(metadata["pr94"]["implementationHead"], "ff0ea1a6e91c3af0996f406dac0acf9f607cc166")
        self.assertEqual(
            metadata["pr94"]["state"],
            "merged-to-parent-not-main-or-device-certified",
        )

    def test_schema_and_pr94_state_drift_fail_closed(self) -> None:
        path, metadata, entries = self._fixture()
        metadata["scopeRoots"] = ["apps/desktop/src"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(desktop_delta.CheckError, "scopeRoots"):
            desktop_delta.load(path)

        path, metadata, entries = self._fixture()
        metadata["historyPathKinds"][0]["kind"] = "not-a-kind"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(desktop_delta.CheckError, "path kind"):
            desktop_delta.load(path)

        path, metadata, entries = self._fixture()
        metadata["pr94"]["state"] = "merged-and-certified"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(desktop_delta.CheckError, "PR94"):
            desktop_delta.load(path)

        path, metadata, entries = self._fixture()
        entries[1]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(desktop_delta.CheckError, "duplicate"):
            desktop_delta.load(path)

    def test_every_row_policy_rejects_model_and_parent_union_drift(self) -> None:
        metadata, entries = desktop_delta.load(self.source)
        commits, parent_counts, paths_by_commit, predecessors = self._inventory(entries)
        desktop_delta._verify_entry_inventory(
            metadata, entries, commits, parent_counts, paths_by_commit, predecessors
        )

        model_entries = [dict(row) for row in entries]
        model_row = next(row for row in model_entries if row["commit"] == "1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4")
        model_row["classification"] = "desktop-only"
        with self.assertRaisesRegex(desktop_delta.CheckError, "policy drift"):
            desktop_delta._verify_entry_inventory(
                metadata, model_entries, commits, parent_counts, paths_by_commit, predecessors
            )

        union_entries = [dict(row) for row in entries]
        merge_row = next(row for row in union_entries if int(row["parentCount"]) > 1)
        merge_row["paths"] = merge_row["paths"].split(";")[0]
        with self.assertRaisesRegex(desktop_delta.CheckError, "merge-parent path union"):
            desktop_delta._verify_entry_inventory(
                metadata, union_entries, commits, parent_counts, paths_by_commit, predecessors
            )

    def test_path_category_retains_generated_test_support_partition(self) -> None:
        self.assertEqual(
            desktop_delta._path_category("apps/desktop/src/test/react-root.ts"),
            "test_fixture",
        )
        self.assertEqual(
            desktop_delta._path_category("apps/desktop/src/i18n/en.ts"),
            "locale",
        )
        self.assertEqual(
            desktop_delta._path_category("apps/desktop/src/store/updates.ts"),
            "production",
        )


if __name__ == "__main__":
    unittest.main()
