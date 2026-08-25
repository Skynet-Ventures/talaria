from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check_hermes_gateway_platform_delta.py")
SPEC = importlib.util.spec_from_file_location("gateway_platform_delta", SCRIPT)
assert SPEC and SPEC.loader
gateway_platform_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gateway_platform_delta)


class GatewayPlatformDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = SCRIPT.parents[1] / "parity" / "hermes-gateway-platform-delta-40643cba-057dcdf.json"

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
            writer = csv.DictWriter(handle, fieldnames=gateway_platform_delta.FIELDS, delimiter="\t")
            writer.writeheader(); writer.writerows(entries)

    def test_repository_ledger_loads_with_exact_partition_and_pr95_status(self) -> None:
        metadata, entries = gateway_platform_delta.load(self.source)
        self.assertEqual(metadata["scopedCommitCount"], 82)
        self.assertEqual(len(entries), 48)
        self.assertEqual(len(metadata["historyPathUnion"]), 43)
        self.assertEqual(len(metadata["finalNetFiles"]), 22)
        self.assertEqual(metadata["crossReferenceCounts"], {
            "authority": 3, "client-wire": 21, "core-runtime": 10,
        })
        self.assertEqual(metadata["talariaSlices"][0]["head"], gateway_platform_delta.EXPECTED_PR95_HEAD)
        self.assertEqual(metadata["talariaSlices"][0]["status"], "implemented-unmerged-live-device-proof-open")

    def test_scope_count_and_cross_reference_drift_fail_closed(self) -> None:
        path, metadata, entries = self._fixture()
        metadata["excludedPathComponents"].pop()
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(gateway_platform_delta.CheckError, "scope drift"):
            gateway_platform_delta.load(path)

        path, metadata, entries = self._fixture()
        metadata["crossReferences"][0]["ledgerHead"] = "0" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(gateway_platform_delta.CheckError, "ledger head drift"):
            gateway_platform_delta.load(path)

        path, metadata, entries = self._fixture()
        entries[1]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(gateway_platform_delta.CheckError, "duplicate commit"):
            gateway_platform_delta.load(path)

    def test_pr95_must_remain_unmerged_and_not_device_certified(self) -> None:
        path, metadata, entries = self._fixture()
        metadata["talariaSlices"][0]["status"] = "merged-device-certified"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(gateway_platform_delta.CheckError, "PR95 slice status/head drift"):
            gateway_platform_delta.load(path)

    def test_exact_checkout_rejects_every_parent_inventory_drift(self) -> None:
        metadata, entries = gateway_platform_delta.load(self.source)
        expected = {row["commit"]: row["paths"].split(";") for row in entries}
        expected.update({row["commit"]: row["paths"] for row in metadata["crossReferences"]})
        commits = list(expected)

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
                return "\n".join(expected[arguments[3]])
            raise AssertionError(arguments)

        hashes = {
            (endpoint, row["path"]): row[field]
            for row in metadata["finalNetFiles"]
            for endpoint, field in ((metadata["baseCommit"], "baseSha256"), (metadata["targetCommit"], "targetSha256"))
        }
        with mock.patch.object(gateway_platform_delta, "_git", side_effect=fake_git), \
             mock.patch.object(gateway_platform_delta, "_blob_hash", side_effect=lambda _c, e, p: hashes[(e, p)]), \
             mock.patch.object(gateway_platform_delta, "_verify_assertions", return_value=None):
            gateway_platform_delta.verify_checkout(metadata, entries, Path("/exact"), verify_talaria=False)
            entries[0]["paths"] = metadata["historyPathUnion"][0]
            with self.assertRaisesRegex(gateway_platform_delta.CheckError, "every-parent gateway inventory drift"):
                gateway_platform_delta.verify_checkout(metadata, entries, Path("/exact"), verify_talaria=False)

    def test_source_assertions_fail_closed(self) -> None:
        metadata, _ = gateway_platform_delta.load(self.source)
        with mock.patch.object(gateway_platform_delta, "_git_bytes", return_value=b"unrelated"):
            with self.assertRaisesRegex(gateway_platform_delta.CheckError, "source assertion drift"):
                gateway_platform_delta._verify_assertions(
                    Path("/exact"), metadata["targetCommit"], metadata["sourceAssertions"], "upstream"
                )


if __name__ == "__main__":
    unittest.main()
