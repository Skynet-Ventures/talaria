from __future__ import annotations

import csv
import importlib.util
import json
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_hermes_authority_delta.py")
SPEC = importlib.util.spec_from_file_location("authority_delta", SCRIPT)
assert SPEC and SPEC.loader
authority_delta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(authority_delta)


class AuthorityDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = SCRIPT.parents[1] / "parity" / "hermes-authority-delta-40643cba-057dcdf.json"

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

    def test_repository_ledger_loads_with_exact_count(self) -> None:
        metadata, entries = authority_delta.load(self.source)
        self.assertEqual(metadata["entryCount"], 63)
        self.assertEqual(len(entries), 63)

    def test_duplicate_commit_fails(self) -> None:
        path, metadata, entries = self._copy_fixture()
        entries[1]["commit"] = entries[0]["commit"]
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(authority_delta.CheckError, "duplicate commit"):
            authority_delta.load(path)

    def test_missing_commit_fails(self) -> None:
        path, metadata, entries = self._copy_fixture()
        entries.pop()
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(authority_delta.CheckError, "entry count mismatch"):
            authority_delta.load(path)

    def test_endpoint_or_hash_drift_fails(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["targetCommit"] = "x" * 40
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(authority_delta.CheckError, "targetCommit"):
            authority_delta.load(path)
        metadata["targetCommit"] = "0" * 40
        metadata["authorityFiles"][0]["targetSha256"] = "z" * 64
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(authority_delta.CheckError, "invalid authority hash"):
            authority_delta.load(path)

    def test_exact_checkout_rejects_valid_looking_endpoint_and_hash_drift(self) -> None:
        directory = Path(tempfile.mkdtemp())
        checkout = directory / "upstream"
        checkout.mkdir()
        self._git(checkout, "init", "-q")
        self._git(checkout, "config", "user.email", "audit@example.invalid")
        self._git(checkout, "config", "user.name", "Audit Fixture")
        source = checkout / "authority.txt"
        source.write_text("base\n")
        self._git(checkout, "add", "authority.txt")
        self._git(checkout, "commit", "-qm", "base")
        base = self._git(checkout, "rev-parse", "HEAD")
        source.write_text("target\n")
        self._git(checkout, "commit", "-qam", "target")
        target = self._git(checkout, "rev-parse", "HEAD")

        metadata = {
            "schemaVersion": 1,
            "repository": "fixture",
            "baseCommit": base,
            "targetCommit": target,
            "entryCount": 1,
            "entriesFile": "entries.tsv",
            "clusterCounts": {"C": 1},
            "authorityFiles": [{
                "path": "authority.txt",
                "baseSha256": hashlib.sha256(b"base\n").hexdigest(),
                "targetSha256": hashlib.sha256(b"target\n").hexdigest(),
            }],
        }
        entries = [{
            "commit": target, "paths": "authority.txt", "cluster": "C",
            "disposition": "desktop-only", "contract": "fixture",
            "evidence": "fixture", "required": "fixture",
        }]
        path = directory / "metadata.json"
        self._write(path, metadata, entries)
        loaded, rows = authority_delta.load(path)
        authority_delta.verify_checkout(loaded, rows, checkout)

        loaded["targetCommit"] = base
        with self.assertRaises(authority_delta.CheckError):
            authority_delta.verify_checkout(loaded, rows, checkout)
        loaded["targetCommit"] = target
        loaded["authorityFiles"][0]["targetSha256"] = "0" * 64
        with self.assertRaisesRegex(authority_delta.CheckError, "targetSha256 drift"):
            authority_delta.verify_checkout(loaded, rows, checkout)

    @staticmethod
    def _write(path: Path, metadata: dict, entries: list[dict[str, str]]) -> None:
        path.write_text(json.dumps(metadata))
        entries_path = path.parent / metadata["entriesFile"]
        with entries_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=authority_delta.FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(entries)

    @staticmethod
    def _git(checkout: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(checkout), *arguments], check=True,
            capture_output=True, text=True,
        ).stdout.strip()


if __name__ == "__main__":
    unittest.main()
