from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check_hermes_cli_delta.py")
SPEC = importlib.util.spec_from_file_location("cli_delta", SCRIPT)
assert SPEC and SPEC.loader
cli_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli_delta)


class CLIDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (
            SCRIPT.parents[1]
            / "parity"
            / "hermes-cli-delta-40643cba-057dcdf.json"
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

    @staticmethod
    def _write(path: Path, metadata: dict, entries: list[dict[str, str]]) -> None:
        path.write_text(json.dumps(metadata))
        entries_path = path.parent / metadata["entriesFile"]
        with entries_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=cli_delta.FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(entries)

    def test_repository_manifest_has_exact_every_parent_accounting(self) -> None:
        metadata, entries = cli_delta.load(self.source)
        self.assertEqual(metadata["scopedCommitCount"], 167)
        self.assertEqual(metadata["scopedMergeCount"], 30)
        self.assertEqual(metadata["historyPathCount"], 124)
        self.assertEqual(metadata["rawHistoryPathCount"], 126)
        self.assertEqual(len(entries), 167)
        self.assertEqual(len(metadata["finalNetFiles"]), 50)
        self.assertEqual(metadata["predecessorCounts"], {
            "authority": 6, "client-wire": 17, "core-runtime": 20,
        })
        self.assertEqual(
            sum(1 for row in entries if row["predecessors"] != "none"), 43,
        )

    def test_scope_cluster_and_reference_drift_fail_closed(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["scopeRules"]["root"] = "hermes_cli/not-real/"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(cli_delta.CheckError, "scope rules drift"):
            cli_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        entries[0]["classification"] = "portable-mobile-runtime"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(cli_delta.CheckError, "cluster semantics drift"):
            cli_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["predecessorLedgers"]["core-runtime"]["head"] = "0" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(cli_delta.CheckError, "predecessor ledger pins drift"):
            cli_delta.load(path)

    def test_critical_contract_and_pr94_reference_are_pinned(self) -> None:
        metadata, entries = cli_delta.load(self.source)
        rearm = next(row for row in entries if row["commit"] == (
            "a0ca7c19204e514f9590ce3b812e029b315ab9e9"
        ))
        self.assertEqual(rearm["classification"], "upstream-contract")
        self.assertEqual(rearm["disposition"], "upstream-contract-blocked")
        self.assertTrue(rearm["predecessors"].startswith("core-runtime:"))
        pr94 = next(row for row in metadata["talariaReferences"] if row["id"] == (
            "PR94-model-discount-presentation"
        ))
        self.assertEqual(pr94["commit"], "5cb68d2dd38539b2f5de789e7be95a545437ca22")
        self.assertEqual(pr94["state"], "merged-to-parent-not-main-uncertified")
        self.assertEqual(pr94["upstreamCommits"], [
            "1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4",
            "bd93a5f3160dc84d1891e27b49bffeb88483d8f0",
        ])

    def test_source_and_reference_parent_drift_fail_closed(self) -> None:
        metadata, _entries = cli_delta.load(self.source)
        with mock.patch.object(cli_delta, "_git_bytes", return_value=b"unrelated source"):
            with self.assertRaisesRegex(cli_delta.CheckError, "source assertion drift"):
                cli_delta._verify_source_assertions(metadata, Path("/exact"))

        absence_only = {
            "targetCommit": metadata["targetCommit"],
            "sourceAssertions": [],
            "sourceAbsenceAssertions": metadata["sourceAbsenceAssertions"],
        }
        with mock.patch.object(cli_delta, "_git_bytes", return_value=b"rearm"):
            with self.assertRaisesRegex(cli_delta.CheckError, "source absence assertion drift"):
                cli_delta._verify_source_assertions(absence_only, Path("/exact"))

        def fake_local_git(*arguments: str) -> str:
            if arguments[0] == "show":
                return "0" * 40
            return ""

        with mock.patch.object(cli_delta, "_local_git", side_effect=fake_local_git):
            with self.assertRaisesRegex(cli_delta.CheckError, "Talaria reference parent drift"):
                cli_delta._verify_talaria_references(metadata)


if __name__ == "__main__":
    unittest.main()
