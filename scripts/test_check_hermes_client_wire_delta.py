from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check_hermes_client_wire_delta.py")
SPEC = importlib.util.spec_from_file_location("client_wire_delta", SCRIPT)
assert SPEC and SPEC.loader
client_wire_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(client_wire_delta)


class ClientWireDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (
            SCRIPT.parents[1]
            / "parity"
            / "hermes-client-wire-delta-40643cba-057dcdf.json"
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
        metadata, entries = client_wire_delta.load(self.source)
        self.assertEqual(metadata["scopedCommitCount"], 71)
        self.assertEqual(metadata["authorityIntersectionCount"], 7)
        self.assertEqual(len(entries), 64)
        self.assertEqual(len(metadata["historyPathUnion"]), 22)
        self.assertEqual(len(metadata["finalNetFiles"]), 12)

    def test_duplicate_or_missing_commit_fails(self) -> None:
        path, metadata, entries = self._copy_fixture()
        entries[1]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "duplicate commit"):
            client_wire_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        entries.pop()
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "entry count mismatch"):
            client_wire_delta.load(path)

    def test_cross_reference_cannot_duplicate_new_ledger(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["crossReferences"][0]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "cross-reference"):
            client_wire_delta.load(path)

    def test_endpoint_path_and_hash_drift_fail_closed(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["targetCommit"] = "x" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "targetCommit"):
            client_wire_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["finalNetFiles"][0]["targetSha256"] = "z" * 64
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "targetSha256"):
            client_wire_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        metadata["historyPathUnion"].append(metadata["historyPathUnion"][0])
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "historyPathUnion"):
            client_wire_delta.load(path)

    def test_invalid_impact_or_disposition_fails(self) -> None:
        path, metadata, entries = self._copy_fixture()
        entries[0]["impact"] = "request,none"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "invalid impact"):
            client_wire_delta.load(path)

        path, metadata, entries = self._copy_fixture()
        entries[0]["disposition"] = "probably-fine"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(client_wire_delta.CheckError, "invalid disposition"):
            client_wire_delta.load(path)

    def test_exact_checkout_verifier_rejects_validly_shaped_hash_drift(self) -> None:
        metadata, entries = client_wire_delta.load(self.source)
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

        def fake_git(_checkout: Path, *arguments: str) -> str:
            if arguments[0] == "cat-file":
                return ""
            if arguments[0] == "log":
                return "\n".join(commits)
            if arguments[:3] == ("show", "-s", "--format=%P"):
                return "parent"
            if arguments[:2] == ("diff", "--name-only"):
                if arguments[2] == (
                    f"{metadata['baseCommit']}..{metadata['targetCommit']}"
                ):
                    return "\n".join(row["path"] for row in metadata["finalNetFiles"])
                return "\n".join(paths_by_commit[arguments[3]])
            raise AssertionError(arguments)

        with mock.patch.object(client_wire_delta, "_git", side_effect=fake_git), mock.patch.object(
            client_wire_delta,
            "_blob_hash",
            side_effect=lambda _checkout, endpoint, path: actual_hashes[(endpoint, path)],
        ):
            client_wire_delta.verify_checkout(metadata, entries, Path("/exact"))
            metadata["finalNetFiles"][0]["targetSha256"] = "0" * 64
            with self.assertRaisesRegex(client_wire_delta.CheckError, "targetSha256 drift"):
                client_wire_delta.verify_checkout(metadata, entries, Path("/exact"))

    @staticmethod
    def _write(path: Path, metadata: dict, entries: list[dict[str, str]]) -> None:
        path.write_text(json.dumps(metadata))
        entries_path = path.parent / metadata["entriesFile"]
        with entries_path.open("w", newline="") as handle:
            writer = csv.DictWriter(
                handle, fieldnames=client_wire_delta.FIELDS, delimiter="\t"
            )
            writer.writeheader()
            writer.writerows(entries)


if __name__ == "__main__":
    unittest.main()
