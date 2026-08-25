from __future__ import annotations

import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check_hermes_residual_runtime_delta.py")
SPEC = importlib.util.spec_from_file_location("residual_runtime_delta", SCRIPT)
assert SPEC and SPEC.loader
residual = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(residual)

UPSTREAM = Path("/Users/joshua/talaria/hermes-agent-upstream")


class ResidualRuntimeDeltaCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (
            SCRIPT.parents[1]
            / "parity"
            / "hermes-residual-runtime-delta-40643cba-057dcdf.json"
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
            writer = csv.DictWriter(handle, fieldnames=residual.FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(entries)

    def test_exact_every_parent_inventory_and_blockers(self) -> None:
        metadata, entries = residual.load(self.source)
        self.assertEqual(metadata["scopedCommitCount"], 201)
        self.assertEqual(metadata["scopedMergeCount"], 34)
        self.assertEqual(metadata["historyPathCount"], 303)
        self.assertEqual(len(metadata["finalNetFiles"]), 67)
        self.assertEqual(len(entries), 201)
        self.assertEqual(metadata["classificationCounts"].get("portable-gap", 0), 0)
        self.assertEqual(metadata["predecessorCounts"], {
            "authority": 9,
            "client-wire": 31,
            "core-runtime": 30,
            "desktop-current": 35,
            "cli-current": 57,
            "gateway-platform-current": 9,
        })
        rows = {row["commit"]: row for row in entries}
        self.assertEqual(rows[residual.REARM_COMMIT]["classification"], "upstream-contract-blocked")
        self.assertEqual(rows[residual.AUXILIARY_BLOCKED_COMMIT]["classification"], "upstream-contract-blocked")
        self.assertEqual(rows["1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4"]["talariaStatus"], "pr94-parent-merged-not-main-uncertified")

    def test_scope_exclusions_are_bounded_and_explicit(self) -> None:
        self.assertTrue(residual._is_residual_production_path("agent/compaction_display.py"))
        self.assertTrue(residual._is_residual_production_path("web/src/pages/ModelsPage.tsx"))
        self.assertTrue(residual._is_residual_production_path("cli.py"))
        self.assertFalse(residual._is_residual_production_path("apps/desktop/src/App.tsx"))
        self.assertFalse(residual._is_residual_production_path("gateway/server.py"))
        self.assertFalse(residual._is_residual_production_path("hermes_cli/main.py"))
        self.assertFalse(residual._is_residual_production_path("tui_gateway/server.py"))
        self.assertFalse(residual._is_residual_production_path("cron/jobs.py"))
        self.assertFalse(residual._is_residual_production_path("web/src/App.test.tsx"))
        self.assertFalse(residual._is_residual_production_path("website/docs/guide.md"))
        self.assertFalse(residual._is_residual_production_path("web/src/app.css"))
        self.assertFalse(residual._is_residual_production_path("ui-tui/vite.config.ts"))
        self.assertFalse(residual._is_residual_production_path("package-lock.json"))

    def test_metadata_and_tsv_corruption_fail_closed(self) -> None:
        path, metadata, entries = self._copy_fixture()
        metadata["scopeRules"]["includedTopLevelPython"] = False
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(residual.CheckError, "residual scope rules drift"):
            residual.load(path)

        path, metadata, entries = self._copy_fixture()
        entries[0]["classification"] = "portable-gap"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(residual.CheckError, "cluster semantics drift"):
            residual.load(path)

        path, metadata, entries = self._copy_fixture()
        entries[0]["paths"] = "docs/not-runtime.md"
        self._write(path, metadata, entries)
        with self.assertRaisesRegex(residual.CheckError, "invalid residual paths"):
            residual.load(path)

    def test_source_and_current_predecessor_corruption_fail_closed(self) -> None:
        metadata, _entries = residual.load(self.source)
        with mock.patch.object(residual, "_git_bytes", return_value=b"unrelated source"):
            with self.assertRaisesRegex(residual.CheckError, "source assertion drift"):
                residual._verify_source_assertions(metadata, Path("/exact"))

        corrupted = json.loads(json.dumps(metadata))
        corrupted["predecessorLedgers"]["desktop-current"]["entriesSha256"] = "0" * 64
        with self.assertRaisesRegex(residual.CheckError, "current predecessor hash drift"):
            residual._read_predecessor_rows(corrupted)

        with mock.patch.object(residual, "_local_git", return_value="0" * 40):
            with self.assertRaisesRegex(residual.CheckError, "Talaria reference parent drift"):
                residual._verify_talaria_references(metadata)

    @unittest.skipUnless(UPSTREAM.exists(), "exact Hermes upstream checkout is unavailable")
    def test_real_checkout_recomputes_every_parent_union_and_endpoint_hashes(self) -> None:
        metadata, entries = residual.load(self.source)
        residual.verify_checkout(metadata, entries, UPSTREAM)


if __name__ == "__main__":
    unittest.main()
